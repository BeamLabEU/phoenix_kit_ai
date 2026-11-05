defmodule PhoenixKitAI.VisionAnswerShapesTest do
  @moduledoc """
  Vision answers a verb cannot use, and how a batch treats them. A paid call must
  end as an error with a usage row: never as a raise (no row, so the caps never
  see the money), and never as a cached success that says nothing was found.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias PhoenixKitAI.{Box, Request}
  alias PhoenixKitAI.Images.Regions
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9>>
  @tokens %{"prompt_tokens" => 1_000, "completion_tokens" => 200, "total_tokens" => 1_200}
  @model "google/gemini-3.8-flash"

  setup do
    PhoenixKitAI.RequestCache.clear()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  defp endpoint do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Shapes #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: @model,
        api_key: "sk-or-v1-test-key"
      })

    endpoint
  end

  defp answer(content, choice \\ %{}) do
    %{
      "model" => @model,
      "choices" => [
        Map.merge(%{"message" => %{"role" => "assistant", "content" => content}}, choice)
      ],
      "usage" => Map.put(@tokens, "cost", 0.0004)
    }
  end

  defp stub_answer(content, choice \\ %{}) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :provider_called)
      Req.Test.json(conn, answer(content, choice))
    end)
  end

  defp stub_by_request(fun) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      fun.(conn, Jason.decode!(raw)["model"], raw)
    end)
  end

  defp rows(endpoint),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid))

  defp refused(conn, status, message) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => %{"message" => message}})
  end

  describe "a JSON array where the verb reads an object" do
    @array Jason.encode!([%{"label" => "logo", "box_2d" => [1, 2, 3, 4]}])

    test "detect_regions/4 is an unparsed answer with its row, and is not cached" do
      ep = endpoint()
      stub_answer(@array)

      for _ <- 1..2 do
        assert {:error, {:no_json_in_response, _}} = PhoenixKitAI.detect_regions(ep.uuid, @jpeg)
        assert_received :provider_called
      end

      assert [%{metadata: %{"unparsed" => true}}, %{metadata: %{"unparsed" => true}}] = rows(ep)
    end

    test "describe_image/3 with regions: is an unparsed answer with its row" do
      ep = endpoint()
      stub_answer(@array)

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, regions: true)

      assert [%{metadata: %{"unparsed" => true}}] = rows(ep)
    end

    test "extract_text/3 is an unparsed answer, also for a list lifted out of prose" do
      ep = endpoint()

      for content <- [@array, "No text found [0]"] do
        stub_answer(content)
        assert {:error, {:no_json_in_response, _}} = PhoenixKitAI.extract_text(ep.uuid, @jpeg)
      end

      assert [_, _] = rows(ep)
    end

    test "fallback_models: moves on, and the billed attempt is listed" do
      ep = endpoint()

      stub_by_request(fn conn, model, _raw ->
        content = if model == "other/model", do: ~s({"regions":[]}), else: @array
        Req.Test.json(conn, answer(content))
      end)

      assert {:ok, %{regions: [], fallbacks: [%{error: :no_json_in_response}]}} =
               PhoenixKitAI.detect_regions(ep.uuid, @jpeg, nil, fallback_models: ["other/model"])
    end

    test "in a batch it is an :unparsed item whose cost reaches the total" do
      ep = endpoint()
      stub_answer(@array)

      assert {:ok, %{items: [%{status: :unparsed, cost: %Decimal{} = cost}]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], verb: :detect_regions, cache: false)

      assert Decimal.gt?(cost, 0)
    end

    test "a caller who asked for any JSON still gets the array" do
      ep = endpoint()
      stub_answer("[1, 2]")

      assert {:ok, %{json: [1, 2]}} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, json: true)
    end
  end

  describe "an object with no regions list" do
    test "is unparsed, where a real empty answer is not" do
      ep = endpoint()

      for content <- [~s({"objects":[{"label":"logo"}]}), ~s({"regions":null})] do
        stub_answer(content)

        assert {:error, {:no_json_in_response, _}} = PhoenixKitAI.detect_regions(ep.uuid, @jpeg)

        assert {:error, {:no_json_in_response, _}} =
                 PhoenixKitAI.describe_image(ep.uuid, @jpeg, regions: true)
      end

      stub_answer(~s({"regions":[]}))

      assert {:ok, %{regions: [], dropped_regions: 0}} =
               PhoenixKitAI.detect_regions(ep.uuid, @jpeg)
    end
  end

  describe "a 200 with nothing usable in it" do
    test "a content filter is a safety refusal: billed, not cached, and another model tries" do
      ep = endpoint()
      stub_answer(nil, %{"finish_reason" => "content_filter"})

      for _ <- 1..2 do
        assert {:error, {:content_policy, _}} =
                 PhoenixKitAI.describe_image(ep.uuid, @jpeg, cache: true)

        assert_received :provider_called
      end

      assert [%{metadata: %{"unparsed" => true}}, _] = rows(ep)

      stub_by_request(fn conn, model, _raw ->
        if model == "other/model",
          do: Req.Test.json(conn, answer("a cat")),
          else: Req.Test.json(conn, answer(nil, %{"finish_reason" => "content_filter"}))
      end)

      assert {:ok, %{text: "a cat", fallbacks: [%{error: :content_policy}]}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, fallback_models: ["other/model"])
    end

    test "text a filter cut short is not a complete answer" do
      ep = endpoint()
      stub_answer("Half a sent", %{"finish_reason" => "content_filter"})

      assert {:error, {:content_policy, reason}} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)
      refute reason =~ "Half a sent"
    end

    test "no text at all is an error, with the row of the billed call" do
      ep = endpoint()

      for content <- [nil, "", "   "] do
        stub_answer(content)
        assert {:error, :empty_response} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)
      end

      assert [_, _, _] = rows(ep)
      assert PhoenixKitAI.fallback_reason?(:empty_response)
    end

    test "a batch item with no text is not reported :ok" do
      ep = endpoint()
      stub_answer(nil)

      assert {:ok, %{items: [%{status: :error, error: :empty_response, cost: %Decimal{}}]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], cache: false)
    end
  end

  describe "a fallback model that is refused" do
    test "does not stop the batch, and the item keeps the reason it failed for" do
      ep = endpoint()

      stub_by_request(fn conn, model, raw ->
        cond do
          model == "retired/x" -> refused(conn, 400, "retired/x is not a valid model ID")
          raw =~ "image/jpeg" -> refused(conn, 400, "Blocked by the safety system")
          true -> Req.Test.json(conn, answer("a dog"))
        end
      end)

      assert {:ok, %{items: [one, two]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png],
                 fallback_models: ["retired/x"],
                 concurrency: 1,
                 cache: false
               )

      assert %{status: :error, error: {:content_policy, _}} = one
      assert %{status: :ok, result: %{text: "a dog"}} = two
    end

    test "a cap reached on the fallback attempt is still what the caller hears" do
      ep = endpoint()
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:global, "0.50")

      # The first attempt spends past the cap and is refused, so the cap is only
      # reached when the fallback is tried: this refusal concerns no model.
      stub_by_request(fn conn, _model, _raw ->
        TestRepo.insert!(%Request{
          model: "m",
          request_type: "chat",
          status: "success",
          cost: Decimal.new(1)
        })

        refused(conn, 400, "Blocked by the safety system")
      end)

      assert {:error, {:budget_exceeded, :global}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, fallback_models: ["other/model"])
    end
  end

  describe "vision_batch/3 with group:" do
    defp grouped(items) do
      Jason.encode!(%{"items" => items})
    end

    test "one unreadable image fails only its own item" do
      ep = endpoint()

      stub_by_request(fn conn, _model, raw ->
        content =
          if raw =~ "separate items",
            do: grouped([%{"item" => 1, "answer" => "cat"}, %{"item" => 2, "answer" => "dog"}]),
            else: "a cat"

        Req.Test.json(conn, answer(content))
      end)

      assert {:ok, %{items: [one, two, three]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, <<0, 1, 2>>, @png],
                 group: 3,
                 concurrency: 1,
                 cache: false
               )

      assert %{status: :ok} = one
      assert %{status: :error, error: :invalid_image_input} = two
      assert %{status: :ok} = three
    end

    test "an item with no images is refused alone, as it would be without group:" do
      ep = endpoint()

      stub_by_request(fn conn, _model, _raw -> Req.Test.json(conn, answer("a cat")) end)

      assert {:ok, %{items: [%{status: :ok}, %{status: :error, error: :empty_input}]}} =
               PhoenixKitAI.vision_batch(
                 ep.uuid,
                 [%{id: "a", images: [@jpeg]}, %{id: "b", images: []}],
                 group: 2,
                 concurrency: 1,
                 cache: false
               )
    end

    test "question: reaches a grouped call, as it reaches a single one" do
      ep = endpoint()
      test = self()

      stub_by_request(fn conn, _model, raw ->
        send(test, {:asked, raw})

        Req.Test.json(
          conn,
          answer(grouped([%{"item" => 1, "answer" => "a"}, %{"item" => 2, "answer" => "b"}]))
        )
      end)

      assert {:ok, %{items: [%{status: :ok}, %{status: :ok}]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png],
                 group: 2,
                 question: "Is the label straight?",
                 cache: false
               )

      assert_received {:asked, raw}
      assert raw =~ "Is the label straight?"
    end

    test "a model counting from 0 that leaves one out is not moved onto the wrong item" do
      ep = endpoint()

      stub_answer(grouped([%{"item" => 0, "answer" => "cat"}, %{"item" => 1, "answer" => "dog"}]))

      assert {:ok, %{items: [one, two, three]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png, @jpeg], group: 3, cache: false)

      assert %{status: :ok, result: %{text: "cat"}} = one
      assert %{status: :ok, result: %{text: "dog"}} = two
      assert %{status: :error, error: :missing_in_group} = three
    end
  end

  describe "statements" do
    test "a model counting from 0 keeps each verdict on its own statement" do
      statements = [%{id: "a", text: "first"}, %{id: "b", text: "second"}]

      json = %{
        "results" => [
          %{"n" => 0, "verdict" => "supported", "evidence" => "of the first"},
          %{"n" => 1, "verdict" => "supported", "evidence" => "of the second"}
        ]
      }

      assert [%{id: "a", evidence: "of the first"}, %{id: "b", evidence: "of the second"}] =
               Regions.parse_statements(json, statements, @model, 1)
    end

    test "a caller's cache key does not serve the verdicts of other statements" do
      ep = endpoint()
      stub_answer(~s({"results":[]}))

      for text <- ["The label is red", "The label is blue"] do
        assert {:ok, _} =
                 PhoenixKitAI.check_statements(ep.uuid, [text], @jpeg, cache: [key: "listing-1"])

        assert_received :provider_called
      end
    end

    test "the same statements under a caller's key still hit" do
      ep = endpoint()
      stub_answer(~s({"results":[]}))
      opts = [cache: [key: "listing-2"]]

      assert {:ok, _} = PhoenixKitAI.check_statements(ep.uuid, ["The label is red"], @jpeg, opts)
      assert_received :provider_called
      assert {:ok, _} = PhoenixKitAI.check_statements(ep.uuid, ["The label is red"], @jpeg, opts)
      refute_received :provider_called
    end
  end

  describe "delivery options" do
    test "retry: reaches a vision call" do
      ep = endpoint()
      test = self()
      counter = :counters.new(1, [])

      stub_by_request(fn conn, _model, _raw ->
        :counters.add(counter, 1, 1)
        send(test, :provider_called)

        if :counters.get(counter, 1) == 1,
          do: refused(conn, 503, "overloaded"),
          else: Req.Test.json(conn, answer("a cat"))
      end)

      assert {:ok, %{text: "a cat"}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 retry: [max_attempts: 2, base_delay: 1, max_delay: 1]
               )

      assert_received :provider_called
      assert_received :provider_called
    end

    test "concurrency: reaches compare_images/4 too" do
      start_supervised!(PhoenixKitAI.Limiter)
      ep = endpoint()
      test = self()

      :telemetry.attach(
        "shapes-limiter",
        [:phoenix_kit_ai, :limiter, :rejected],
        fn _event, _measure, meta, _config -> send(test, {:rejected, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("shapes-limiter") end)

      stub_by_request(fn conn, _model, _raw -> Req.Test.json(conn, answer("{}")) end)

      # A limit of 1 with no room in line and the only slot taken here.
      key = "shapes-#{System.unique_integer([:positive])}"
      parent = self()

      holder =
        spawn(fn ->
          PhoenixKitAI.Limiter.run(ep, [concurrency: [limit: 1, key: key]], fn ->
            send(parent, :holding)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :holding, 1_000
      on_exit(fn -> Process.exit(holder, :kill) end)

      assert {:error, :concurrency_queue_full} =
               PhoenixKitAI.compare_images(ep.uuid, @jpeg, @png,
                 concurrency: [limit: 1, key: key, max_waiting: 0, wait: 10]
               )

      assert_received {:rejected, %{key: ^key}}
    end
  end

  test "Qwen's dashed id form reads boxes x first, as its family does" do
    assert Box.format_for("qwen/qwen-2.5-vl-7b-instruct") == :xy_1000
  end
end
