defmodule PhoenixKitAI.VisionEdgeCasesTest do
  @moduledoc """
  The edges of fallbacks, grouped batches, confirmed contradictions and
  error mapping, through the real verbs against `Req.Test` stubs: what each
  costs when it goes wrong, which errors are safety refusals, and how a
  grouped answer is read when the model numbers or shapes it badly.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKitAI.{Completion, Errors, Request}
  alias PhoenixKitAI.Providers.HTTP
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9>>
  @tokens %{"prompt_tokens" => 1_000, "completion_tokens" => 200, "total_tokens" => 1_200}

  setup do
    PhoenixKitAI.RequestCache.clear()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  defp endpoint do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Edges #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-3.8-flash",
        api_key: "sk-or-v1-test-key"
      })

    endpoint
  end

  defp answer(conn, content, opts \\ []) do
    Req.Test.json(conn, %{
      "model" => Keyword.get(opts, :model, "google/gemini-3.8-flash"),
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => Keyword.get(opts, :finish, "stop")
        }
      ],
      "usage" => Map.put(@tokens, "cost", Keyword.get(opts, :cost, 0.001))
    })
  end

  defp body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  defp prompt_of(%{"messages" => messages}) do
    messages
    |> List.last()
    |> Map.get("content")
    |> case do
      [%{"text" => t} | _] -> t
      t when is_binary(t) -> t
    end
  end

  defp rows(ep),
    do:
      TestRepo.all(
        from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.inserted_at)
      )

  defp counting_stub(fun) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {b, conn} = body(conn)
      send(test, {:call, b})
      fun.(conn, b)
    end)
  end

  defp calls do
    receive do
      {:call, _} -> 1 + calls()
    after
      0 -> 0
    end
  end

  defp contradicted(n, evidence),
    do: %{
      "n" => n,
      "verdict" => "contradicted",
      "evidence" => evidence,
      "image" => 1,
      "box_2d" => [100, 100, 500, 500]
    }

  defp supported(n),
    do: %{
      "n" => n,
      "verdict" => "supported",
      "evidence" => "yes",
      "image" => 1,
      "box_2d" => [1, 1, 400, 400]
    }

  describe "cut-off answers" do
    test "the finish reason is read in any case" do
      for reason <- ["length", "LENGTH", "max_tokens", "MAX_TOKENS"] do
        assert Completion.truncated?(%{"choices" => [%{"finish_reason" => reason}]}), reason
      end

      refute Completion.truncated?(%{"choices" => [%{"finish_reason" => "STOP"}]})
      refute Completion.truncated?(%{"choices" => [%{"finish_reason" => nil}]})
    end
  end

  describe "error mapping" do
    test "an account or billing message is never a safety refusal, whatever words it uses" do
      for message <- [
            "Your account is blocked: billing violation",
            "API key blocked for policy violation",
            "Insufficient credit balance; requests are blocked"
          ] do
        body = Jason.encode!(%{"error" => %{"message" => message}})
        refute match?({:error, {:content_policy, _}}, HTTP.error(403, body)), message
      end

      body = Jason.encode!(%{"error" => %{"message" => "Blocked: PROHIBITED_CONTENT"}})
      assert {:error, {:content_policy, _}} = HTTP.error(403, body)
    end

    test "an unknown model is recognised with dots in its id, and billing text is not one" do
      assert Completion.handle_error_status(
               404,
               ~s({"error":{"message":"The model `gpt-4.1-mini` does not exist"}})
             ) == {:error, :model_not_found}

      assert Completion.handle_error_status(
               400,
               ~s({"error":{"code":"model_not_found","message":"No such thing"}})
             ) == {:error, :model_not_found}

      refute Completion.handle_error_status(
               402,
               ~s({"error":{"message":"Insufficient credits: this model was not found in your plan's balance"}})
             ) == {:error, :model_not_found}
    end

    test "an error envelope in a 200 answer is mapped like the status it names, safety included" do
      ep = endpoint()

      counting_stub(fn conn, b ->
        if b["model"] == "google/gemini-2.5-flash-lite",
          do:
            Req.Test.json(conn, %{
              "error" => %{"code" => 403, "message" => "Blocked: PROHIBITED_CONTENT"}
            }),
          else: answer(conn, "A stage.")
      end)

      assert {:ok, %{text: "A stage.", fallbacks: [%{error: :content_policy}]}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 model: "google/gemini-2.5-flash-lite",
                 fallback_models: ["google/gemini-3.8-flash"],
                 cache: false
               )
    end

    test "every new refusal has a message" do
      for reason <- [
            :invalid_fallback_models,
            :invalid_confirm,
            :labels_look_like_options,
            :missing_in_group,
            :model_not_found,
            {:unsupported_option, :group, :extract_text},
            {:output_truncated, "x"},
            {:exception, RuntimeError}
          ] do
        text = Errors.message(reason)
        assert is_binary(text) and text != "", inspect(reason)
        refute text =~ "Unknown error", inspect(reason)
      end
    end
  end

  describe "fallback_models:" do
    test "a request timeout (408) falls back; other 4xx do not" do
      assert PhoenixKitAI.fallback_reason?({:api_error, 408})
      refute PhoenixKitAI.fallback_reason?({:api_error, 404})
    end

    test "entries that are not model ids are refused before any call" do
      ep = endpoint()
      counting_stub(fn conn, _b -> answer(conn, "x") end)

      for bad <- ["m/two", [nil], [""], [:atom], ["ok", 1]] do
        assert {:error, :invalid_fallback_models} =
                 PhoenixKitAI.describe_image(ep.uuid, @jpeg, fallback_models: bad, cache: false),
               inspect(bad)
      end

      assert calls() == 0
    end

    test "when every model fails, the last error comes back and each attempt is a row" do
      ep = endpoint()
      counting_stub(fn conn, b -> answer(conn, "prose", model: b["model"]) end)

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 json: true,
                 fallback_models: ["m/two", "m/three"],
                 cache: false
               )

      assert calls() == 3
      assert length(rows(ep)) == 3
    end

    test "a billed failed attempt names its cost, and a batch item counts every attempt" do
      ep = endpoint()

      counting_stub(fn conn, b ->
        if b["model"] == "google/gemini-3.8-flash",
          do: answer(conn, "prose", cost: 0.003),
          else: answer(conn, ~s({"ok": 1}), model: b["model"], cost: 0.001)
      end)

      assert {:ok, %{fallbacks: [%{model: "google/gemini-3.8-flash", cost: tried_cost}]}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 json: true,
                 fallback_models: ["m/two"],
                 cache: false
               )

      assert Decimal.equal?(tried_cost, Decimal.new("0.003"))

      assert {:ok, %{items: [item], cost: cost}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@png],
                 json: true,
                 fallback_models: ["m/two"],
                 cache: false
               )

      assert item.status == :ok
      assert Decimal.equal?(item.cost, Decimal.new("0.004"))
      assert Decimal.equal?(cost, Decimal.new("0.004"))
    end
  end

  describe "vision_batch/3 group: answers" do
    test "a model that numbers from 0 is read as such" do
      ep = endpoint()

      counting_stub(fn conn, _b ->
        answer(
          conn,
          Jason.encode!(%{
            "items" => [%{"item" => 0, "answer" => "cat"}, %{"item" => 1, "answer" => "dog"}]
          })
        )
      end)

      assert {:ok, %{items: [a, b]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png], group: 2, cache: false)

      assert %{status: :ok, result: %{text: "cat"}} = a
      assert %{status: :ok, result: %{text: "dog"}} = b
    end

    test "a number given twice, an answer of the wrong shape, or a non-list answers nobody, at a share each" do
      ep = endpoint()

      counting_stub(fn conn, b ->
        content =
          if prompt_of(b) =~ "3 separate items",
            do:
              Jason.encode!(%{
                "items" => [
                  %{"item" => 1, "answer" => "cat"},
                  %{"item" => 1, "answer" => "cow"},
                  %{"item" => 2, "answer" => %{"caption" => "dog"}},
                  %{"item" => 3, "answer" => "owl"}
                ]
              }),
            else: Jason.encode!(%{"items" => 0})

        answer(conn, content, cost: 0.003)
      end)

      assert {:ok, %{items: [one, two, three]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png, @jpeg], group: 3, cache: false)

      assert %{status: :error, error: :missing_in_group} = one
      assert %{status: :error, error: :missing_in_group} = two
      assert %{status: :ok, result: %{text: "owl"}} = three

      for item <- [one, two, three],
          do: assert(Decimal.equal?(item.cost, Decimal.new("0.001")))

      assert {:ok, %{items: [x, y], cost: cost}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@png, @jpeg], group: 2, cache: false)

      assert x.error == :missing_in_group and y.error == :missing_in_group
      assert Decimal.equal?(cost, Decimal.new("0.003"))
    end

    test "a group closes before it carries more image bytes than one call may" do
      ep = endpoint()

      counting_stub(fn conn, b ->
        n = if prompt_of(b) =~ "2 separate items", do: 2, else: 1

        content =
          if n == 2,
            do:
              Jason.encode!(%{
                "items" => [%{"item" => 1, "answer" => "a"}, %{"item" => 2, "answer" => "b"}]
              }),
            else: "c"

        answer(conn, content)
      end)

      big = @jpeg <> :binary.copy(<<0>>, 40)

      assert {:ok, %{items: items, counts: %{ok: 3}}} =
               PhoenixKitAI.vision_batch(ep.uuid, [big, big, big],
                 group: 3,
                 max_input_bytes: 60,
                 max_total_input_bytes: 120,
                 cache: false
               )

      assert length(items) == 3
      assert calls() == 2
    end
  end

  describe "vision_batch/3 items" do
    test "an item's own prompt is extra instructions for a verb whose prompt is built in" do
      ep = endpoint()
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)
        send(test, {:prompt, prompt_of(b)})
        answer(conn, ~s({"text": "Title", "lines": ["Title"]}))
      end)

      assert {:ok, %{items: [%{status: status}]}} =
               PhoenixKitAI.vision_batch(
                 ep.uuid,
                 [%{id: 1, images: @jpeg, prompt: "Only the book's title."}],
                 verb: :extract_text,
                 cache: false
               )

      assert status in [:ok, :unparsed]
      assert_receive {:prompt, prompt}
      assert prompt =~ "Only the book's title."
      refute prompt == "Only the book's title."
    end

    test "a crashing item is logged and is an error for that item only" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)
        if prompt_of(b) =~ "CRASH", do: raise("boom"), else: answer(conn, "A chair.")
      end)

      log =
        capture_log(fn ->
          assert {:ok, %{items: [bad, good]}} =
                   PhoenixKitAI.vision_batch(
                     ep.uuid,
                     [%{id: :bad, images: @jpeg, prompt: "CRASH"}, %{id: :good, images: @png}],
                     cache: false
                   )

          assert bad.status == :error
          assert good.status == :ok
        end)

      assert log =~ "[PhoenixKitAI.VisionBatch] item"
    end
  end

  describe "cache keys" do
    test "a caller key does not serve an answer of another shape" do
      ep = endpoint()
      counting_stub(fn conn, _b -> answer(conn, "A chair.") end)

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, cache: [key: "shape:1"])
      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, cache: [key: "shape:1"])
      assert calls() == 1

      assert {:ok, _} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 cache: [key: "shape:1"],
                 box_format: :xy_1000
               )

      assert calls() == 1
    end
  end

  describe "check_statements/4 confirm:" do
    test "an unknown confirm: value is refused before any call" do
      ep = endpoint()
      counting_stub(fn conn, _b -> answer(conn, "x") end)

      for bad <- [:yes, "true", 1, []] do
        assert {:error, :invalid_confirm} =
                 PhoenixKitAI.check_statements(ep.uuid, ["A cat"], @jpeg, confirm: bad),
               inspect(bad)
      end

      assert calls() == 0
    end

    test "the second check is a real call even when the cache holds the first" do
      ep = endpoint()

      counting_stub(fn conn, _b ->
        answer(conn, Jason.encode!(%{"results" => [contradicted(1, "a dog")]}))
      end)

      assert {:ok, %{results: [%{confirmed: true}], confirm_request_uuid: uuid}} =
               PhoenixKitAI.check_statements(ep.uuid, ["A cat"], @jpeg, confirm: true)

      assert calls() == 2
      assert %Request{} = TestRepo.get(Request, uuid)
    end

    test "duplicate statement ids are paired by position" do
      ep = endpoint()

      seen = :counters.new(1, [])

      counting_stub(fn conn, _b ->
        :counters.add(seen, 1, 1)

        # first check: both contradicted; second: agrees on the first only
        results =
          if :counters.get(seen, 1) == 1,
            do: [contradicted(1, "one cat"), contradicted(2, "no lamp")],
            else: [contradicted(1, "only one cat"), supported(2)]

        answer(conn, Jason.encode!(%{"results" => results}))
      end)

      assert {:ok, %{results: [first, second]}} =
               PhoenixKitAI.check_statements(
                 ep.uuid,
                 [{:same, "Two cats"}, {:same, "A lamp"}],
                 @jpeg,
                 confirm: [@png],
                 cache: false
               )

      assert %{evidence: "one cat", confirmed: true, confirm_evidence: "only one cat"} = first
      assert %{evidence: "no lamp", verdict: :insufficient, unconfirmed: true} = second
    end

    test "a failed second check leaves no contradiction standing, names the failure and keeps its cost" do
      ep = endpoint()

      counting_stub(fn conn, b ->
        if length(hd(b["messages"])["content"]) > 2,
          do: answer(conn, "prose, not JSON", cost: 0.002),
          else:
            answer(conn, Jason.encode!(%{"results" => [contradicted(1, "a dog")]}), cost: 0.002)
      end)

      assert {:ok, %{results: [r], counts: counts, cost: cost} = result} =
               PhoenixKitAI.check_statements(ep.uuid, ["A cat"], @jpeg,
                 confirm: [@png, @png],
                 cache: false
               )

      assert %{verdict: :insufficient, unconfirmed: true} = r
      assert counts.contradicted == 0
      assert result.confirm_error == :no_json_in_response
      assert Decimal.equal?(cost, Decimal.new("0.004"))
    end
  end

  describe "detect_regions/4 and embed/3" do
    test "options passed where the labels go are refused" do
      ep = endpoint()

      assert {:error, :labels_look_like_options} =
               PhoenixKitAI.detect_regions(ep.uuid, @jpeg, cache: false)
    end

    test "embed/3 answers with the logged cost" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "model" => "google/gemini-embedding-2",
          "data" => [%{"embedding" => [0.1, 0.2], "index" => 0}],
          "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3, "cost" => 0.0001}
        })
      end)

      assert {:ok, %{"cost" => cost, "request_uuid" => uuid}} =
               PhoenixKitAI.embed(ep.uuid, "a sofa")

      assert %Request{cost: ^cost} = TestRepo.get(Request, uuid)
    end
  end

  describe "runs" do
    test "run tags are trimmed, bounded, and only texts, atoms and integers count" do
      assert PhoenixKitAI.Guard.run_tag("  import-1  ") == "import-1"
      assert PhoenixKitAI.Guard.run_tag(:import) == "import"
      assert PhoenixKitAI.Guard.run_tag(42) == "42"
      assert PhoenixKitAI.Guard.run_tag("   ") == nil
      assert PhoenixKitAI.Guard.run_tag(nil) == nil
      assert PhoenixKitAI.Guard.run_tag(true) == nil
      assert PhoenixKitAI.Guard.run_tag(%{}) == nil
      assert String.length(PhoenixKitAI.Guard.run_tag(String.duplicate("x", 1_000))) < 1_000
    end

    test "get_usage_stats/1 filters by run" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, "A chair."))

      run = "stats-#{System.unique_integer([:positive])}"
      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, run: run, cache: false)
      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @png, run: run, cache: false)
      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @png, run: "other", cache: false)

      assert %{total_requests: 2} = PhoenixKitAI.get_usage_stats(run: run)
    end
  end
end
