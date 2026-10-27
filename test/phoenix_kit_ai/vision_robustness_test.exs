defmodule PhoenixKitAI.VisionRobustnessTest do
  @moduledoc """
  Cut-off answers, fallback models, grouped batches and confirmed
  contradictions, through the real verbs against `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias PhoenixKitAI.Request
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
        name: "Robustness #{System.unique_integer([:positive])}",
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

  describe "cut-off answers" do
    test "a JSON vision answer stopped at the output limit is an error, billed and marked" do
      ep = endpoint()
      # Valid-looking JSON, but the provider says it stopped at max_tokens.
      Req.Test.stub(__MODULE__, &answer(&1, ~s({"ok": true}), finish: "length"))

      assert {:error, {:output_truncated, ~s({"ok": true})}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, json: true, cache: false)

      assert [row] = rows(ep)
      assert row.status == "success"
      assert row.metadata["unparsed"] == true
      assert row.metadata["truncated"] == true
      assert Decimal.gt?(row.cost, 0)
    end

    test "Anthropic's max_tokens finish reason counts too" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, ~s({"text": "A"}), finish: "max_tokens"))

      assert {:error, {:output_truncated, _}} =
               PhoenixKitAI.extract_text(ep.uuid, @jpeg, cache: false)
    end

    test "a text answer that was cut off comes back flagged" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, "A long descripti", finish: "length"))

      assert {:ok, %{text: "A long descripti", truncated: true}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, cache: false)
    end

    test "a complete answer is not flagged" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, "A chair."))

      assert {:ok, %{truncated: false}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, cache: false)
    end

    test "a chat call asking for JSON is refused when cut off" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, ~s({"a": 1}), finish: "length"))

      assert {:error, {:output_truncated, _}} =
               PhoenixKitAI.ask(ep.uuid, "Give JSON", json: true, cache: false)

      assert [%{status: "success"}] = rows(ep)
    end

    test "the error has a message" do
      assert PhoenixKitAI.Errors.message({:output_truncated, "x"}) =~ "max_tokens"
    end
  end

  describe "fallback_models:" do
    test "a safety block on the first model moves to the next, with a row per attempt" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)

        case b["model"] do
          "google/gemini-2.5-flash-lite" ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{
              "error" => %{
                "message" => "Gemini blocked the request: PROHIBITED_CONTENT",
                "code" => 403
              }
            })

          "google/gemini-3.8-flash" ->
            answer(conn, "A cabaret stage.")
        end
      end)

      assert {:ok,
              %{
                text: "A cabaret stage.",
                fallbacks: [%{model: "google/gemini-2.5-flash-lite", error: :content_policy}]
              }} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 model: "google/gemini-2.5-flash-lite",
                 fallback_models: ["google/gemini-3.8-flash"],
                 cache: false
               )

      assert [first, second] = rows(ep)
      assert first.status == "error"
      assert second.status == "success"
      assert second.model == "google/gemini-3.8-flash"
    end

    test "an unparsed answer falls back; the endpoint's own model is named when no model: was given" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)

        if b["model"] == "google/gemini-3.8-flash",
          do: answer(conn, "sorry, prose"),
          else: answer(conn, ~s({"ok": 1}), model: b["model"])
      end)

      assert {:ok,
              %{
                json: %{"ok" => 1},
                fallbacks: [%{model: "google/gemini-3.8-flash", error: :no_json_in_response}]
              }} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 json: true,
                 fallback_models: ["qwen/qwen3-vl-8b"],
                 cache: false
               )
    end

    test "detect_regions and check_statements pass the fallbacks on" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)

        if b["model"] == "google/gemini-3.8-flash",
          do: answer(conn, "no json"),
          else: answer(conn, ~s({"regions": [], "results": []}), model: b["model"])
      end)

      assert {:ok, %{fallbacks: [_]}} =
               PhoenixKitAI.detect_regions(ep.uuid, @jpeg, ["cat"],
                 fallback_models: ["m/two"],
                 cache: false
               )

      assert {:ok, %{fallbacks: [_]}} =
               PhoenixKitAI.check_statements(ep.uuid, ["a cat"], @jpeg,
                 fallback_models: ["m/two"],
                 cache: false
               )
    end

    test "a spend-cap refusal never falls back" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, "A chair.", cost: 0.01))
      {:ok, _} = PhoenixKitAI.Budget.set_limit(:endpoint, "0.005")
      on_exit(fn -> PhoenixKitAI.Budget.set_limit(:endpoint, 0) end)

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, cache: false)

      assert {:error, {:budget_exceeded, :endpoint}} =
               PhoenixKitAI.describe_image(ep.uuid, @png,
                 fallback_models: ["m/two"],
                 cache: false
               )

      assert length(rows(ep)) == 2
    end

    test "which errors fall back" do
      for reason <- [
            {:content_policy, "x"},
            {:output_truncated, "x"},
            {:no_json_in_response, "x"},
            {:api_error, 503},
            :model_not_found,
            :request_timeout
          ] do
        assert PhoenixKitAI.fallback_reason?(reason), inspect(reason)
      end

      for reason <- [
            {:budget_exceeded, :global},
            :invalid_api_key,
            :insufficient_credits,
            :invalid_image_input,
            {:model_unfit, [:vision]},
            {:api_error, 400}
          ] do
        refute PhoenixKitAI.fallback_reason?(reason), inspect(reason)
      end
    end
  end

  describe "vision_batch/3 group:" do
    test "packs items into one call each, answers per item, shares the cost, keeps the order" do
      ep = endpoint()
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)
        p = prompt_of(b)
        send(test, {:call, p, length(hd(b["messages"])["content"]) - 1})

        case Regex.run(~r/covers (\d+) separate items/, p) do
          [_, n] ->
            items =
              for k <- 1..String.to_integer(n), do: %{"item" => k, "answer" => "answer #{k}"}

            answer(conn, Jason.encode!(%{"items" => items}), cost: 0.003)

          nil ->
            answer(conn, "single", cost: 0.001)
        end
      end)

      items = [
        %{id: :a, images: @jpeg},
        %{id: :b, images: [@png, @jpeg]},
        %{id: :c, images: @png},
        %{id: :own, images: @jpeg, prompt: "Alone"},
        %{id: :d, images: @jpeg <> <<1>>}
      ]

      assert {:ok, %{items: results, counts: %{ok: 5}}} =
               PhoenixKitAI.vision_batch(ep.uuid, items,
                 group: 3,
                 prompt: "What is shown?",
                 concurrency: 1,
                 cache: false
               )

      assert Enum.map(results, & &1.id) == [:a, :b, :c, :own, :d]
      [a, b, c, own, d] = results

      assert a.result.text == "answer 1" and b.result.text == "answer 2" and
               c.result.text == "answer 3"

      assert Decimal.equal?(a.cost, Decimal.new("0.001"))
      assert a.result.group_size == 3
      # The plain items go 3 at a time: [a, b, c] then [d] alone; :own has its own prompt.
      assert %{text: "single"} = d.result
      refute Map.has_key?(d.result, :group_size)
      assert %{status: :ok, result: %{text: "single"}} = own

      assert_receive {:call, grouped, 4}
      assert grouped =~ "covers 3 separate items"
      assert grouped =~ "item 2 = images 2-3"
      assert_receive {:call, "What is shown?", 1}
      assert_receive {:call, "Alone", 1}
      refute_receive {:call, _, _}
    end

    test "with a schema each item's answer is its JSON; a missing answer is an error for that item only" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        answer(
          conn,
          Jason.encode!(%{"items" => [%{"item" => 2, "answer" => %{"colour" => "red"}}]})
        )
      end)

      schema = %{
        "type" => "object",
        "properties" => %{"colour" => %{"type" => "string"}},
        "required" => ["colour"],
        "additionalProperties" => false
      }

      assert {:ok, %{items: [first, second]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png],
                 group: 2,
                 schema: schema,
                 cache: false
               )

      assert %{status: :error, error: :missing_in_group} = first
      assert %{status: :ok, result: %{json: %{"colour" => "red"}, text: nil}} = second
    end

    test "an unparsed group answer marks every item unparsed with its share of the billed cost" do
      ep = endpoint()
      Req.Test.stub(__MODULE__, &answer(&1, "prose", cost: 0.004))

      assert {:ok, %{items: [a, b], counts: %{unparsed: 2}}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg, @png], group: 2, cache: false)

      assert Decimal.equal?(a.cost, Decimal.new("0.002"))
      assert b.status == :unparsed
    end

    test "group: is refused where it cannot work" do
      ep = endpoint()

      assert {:error, {:unsupported_option, :group, :extract_text}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], group: 2, verb: :extract_text)

      assert {:error, {:unsupported_option, :group, :json_without_schema}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], group: 2, json: true)

      assert {:error, {:unsupported_option, :group, 20}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], group: 20)
    end
  end

  describe "check_statements/4 contradictions" do
    test "a contradiction that names no image is reported as insufficient" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        answer(
          conn,
          Jason.encode!(%{
            "results" => [
              %{
                "n" => 1,
                "verdict" => "contradicted",
                "evidence" => "seems wrong",
                "image" => 0,
                "box_2d" => [0, 0, 0, 0]
              }
            ]
          })
        )
      end)

      assert {:ok,
              %{
                results: [%{verdict: :insufficient, downgraded: :no_evidence_image}],
                counts: %{contradicted: 0, insufficient: 1}
              }} =
               PhoenixKitAI.check_statements(ep.uuid, ["The sofa is red"], @jpeg, cache: false)
    end

    test "confirm: keeps a contradiction only when the second check agrees" do
      ep = endpoint()
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)
        p = prompt_of(b)
        send(test, {:check, p})

        contradicted = %{
          "verdict" => "contradicted",
          "image" => 1,
          "box_2d" => [100, 100, 500, 500]
        }

        results =
          if p =~ "3. ",
            # first check: all three statements; 1 supported, 2 and 3 contradicted
            do: [
              %{
                "n" => 1,
                "verdict" => "supported",
                "evidence" => "red",
                "image" => 1,
                "box_2d" => [1, 1, 500, 500]
              },
              Map.put(contradicted, "n", 2) |> Map.put("evidence", "one cat"),
              Map.put(contradicted, "n", 3) |> Map.put("evidence", "no lamp")
            ],
            # second check: only the two contradicted ones, renumbered 1 and 2; it agrees on the first only
            else: [
              Map.put(contradicted, "n", 1) |> Map.put("evidence", "only one cat"),
              %{
                "n" => 2,
                "verdict" => "supported",
                "evidence" => "a lamp in the corner",
                "image" => 1,
                "box_2d" => [1, 1, 400, 400]
              }
            ]

        answer(conn, Jason.encode!(%{"results" => results}), cost: 0.002)
      end)

      assert {:ok,
              %{
                results: [sofa, cats, lamp],
                counts: counts,
                cost: cost,
                confirm_request_uuid: uuid
              }} =
               PhoenixKitAI.check_statements(ep.uuid, ["Red sofa", "Two cats", "A lamp"], @jpeg,
                 confirm: true,
                 cache: false
               )

      assert sofa.verdict == :supported
      assert %{verdict: :contradicted, confirmed: true, confirm_evidence: "only one cat"} = cats

      assert %{
               verdict: :insufficient,
               unconfirmed: true,
               evidence: "no lamp",
               confirm_evidence: "a lamp in the corner"
             } = lamp

      assert counts == %{supported: 1, contradicted: 1, insufficient: 1}
      assert Decimal.equal?(cost, Decimal.new("0.004"))
      assert is_binary(uuid)

      assert_receive {:check, first}
      assert_receive {:check, second}
      assert first =~ "3. A lamp"
      assert second =~ "1. Two cats\n2. A lamp"
    end

    test "confirm: with other images sends those; no contradiction means no second call" do
      ep = endpoint()
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {b, conn} = body(conn)
        send(test, {:images, length(hd(b["messages"])["content"]) - 1})

        answer(
          conn,
          Jason.encode!(%{
            "results" => [
              %{
                "n" => 1,
                "verdict" => "supported",
                "evidence" => "yes",
                "image" => 1,
                "box_2d" => [1, 1, 9, 9]
              }
            ]
          })
        )
      end)

      assert {:ok, %{counts: %{supported: 1}} = r} =
               PhoenixKitAI.check_statements(ep.uuid, ["A cat"], @jpeg,
                 confirm: [@png, @png],
                 cache: false
               )

      refute Map.has_key?(r, :confirm_request_uuid)
      assert_receive {:images, 1}
      refute_receive {:images, _}
    end
  end
end
