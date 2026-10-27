defmodule PhoenixKitAI.ImageAIAdditionsTest do
  @moduledoc """
  The generic image additions end to end, through the real verbs (gate,
  cache, usage rows) against `Req.Test` stubs: image embeddings, regions
  and boxes, `detect_regions/4`, `check_statements/4`, run / step tags,
  `run_costs/2` and `vision_batch/3`.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias PhoenixKitAI.{Box, Request}
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

  defp endpoint(attrs \\ %{}) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Additions #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "google/gemini-3.8-flash",
            api_key: "sk-or-v1-test-key"
          },
          Map.new(attrs)
        )
      )

    endpoint
  end

  # Answers every chat call with `json` (encoded) as the content, naming
  # `model` as the model that answered, and sends the request body to the test.
  defp stub_json(json, model \\ "google/gemini-3.8-flash", cost \\ 0.0004) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request_body, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "model" => model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => Jason.encode!(json)}}],
        "usage" => Map.put(@tokens, "cost", cost)
      })
    end)
  end

  defp rows(endpoint),
    do:
      TestRepo.all(
        from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid, order_by: r.inserted_at)
      )

  describe "embed/3 with images" do
    test "sends images as multimodal content parts and names the vector space" do
      ep = endpoint(model: "google/gemini-embedding-2", dimensions: nil)
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "model" => "google/gemini-embedding-2",
          "data" => [
            %{"index" => 0, "embedding" => [0.1, 0.2, 0.3]},
            %{"index" => 1, "embedding" => [0.3, 0.2, 0.1]},
            %{"index" => 2, "embedding" => [0.0, 0.0, 1.0]}
          ],
          "usage" => %{"prompt_tokens" => 600, "total_tokens" => 600, "cost" => 0.0003}
        })
      end)

      assert {:ok,
              %{
                "space" => "google/gemini-embedding-2:3",
                "data" => [_, _, _],
                "request_uuid" => uuid
              }} =
               PhoenixKitAI.embed(ep.uuid, [
                 {:image, @jpeg},
                 %{image: @png, text: "red sofa"},
                 "plain text"
               ])

      assert_received {:request_body, %{"input" => [img, captioned, "plain text"]}}

      assert %{
               "content" => [
                 %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/jpeg;base64," <> _}
                 }
               ]
             } = img

      assert %{"content" => [%{"type" => "text", "text" => "red sofa"}, %{"type" => "image_url"}]} =
               captioned

      row = TestRepo.get!(Request, uuid)
      assert row.request_type == "embedding"
      assert row.metadata["image_count"] == 2
      assert row.metadata["input_count"] == 3
      refute inspect(row.metadata) =~ "base64"
    end

    test "a single image is accepted on its own" do
      ep = endpoint(model: "google/gemini-embedding-2", dimensions: nil)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"index" => 0, "embedding" => [1.0, 0.0]}],
          "usage" => %{"prompt_tokens" => 258}
        })
      end)

      assert {:ok, %{"space" => "google/gemini-embedding-2:2"}} =
               PhoenixKitAI.embed(ep.uuid, {:image, @jpeg})
    end

    test "bad input is refused before any request or row" do
      ep = endpoint(model: "google/gemini-embedding-2")
      Req.Test.stub(__MODULE__, fn _conn -> flunk("no request expected") end)

      assert {:error, :invalid_embedding_input} = PhoenixKitAI.embed(ep.uuid, ["ok", 42])
      assert {:error, :empty_input} = PhoenixKitAI.embed(ep.uuid, [])

      assert {:error, {:unsafe_url, _}} =
               PhoenixKitAI.embed(ep.uuid, [{:image, "http://127.0.0.1/x.jpg"}])

      assert rows(ep) == []
    end
  end

  describe "detect_regions/4" do
    test "finds labelled things, reads the answering model's box format, counts bad boxes" do
      ep = endpoint()

      stub_json(
        %{
          "regions" => [
            %{
              "label" => "logo",
              "description" => "top-left",
              "box_2d" => [100, 200, 300, 400],
              "image" => 1,
              "confidence" => 0.8
            },
            %{
              "label" => "logo",
              "description" => "broken",
              "box_2d" => [5, 5],
              "image" => 1,
              "confidence" => 0.1
            }
          ]
        },
        "qwen/qwen3-vl-235b-a22b-instruct"
      )

      assert {:ok,
              %{
                regions: [region],
                dropped_regions: 1,
                model: "qwen/qwen3-vl-235b-a22b-instruct",
                cost: cost
              }} =
               PhoenixKitAI.detect_regions(ep.uuid, @jpeg, ["logo"],
                 instructions: "Only printed logos."
               )

      # Qwen writes x first: [100, 200, 300, 400] is x 0.1–0.3, y 0.2–0.4.
      assert %Box{x0: 0.1, y0: 0.2, x1: 0.3, y1: 0.4} = region.box
      assert Decimal.equal?(cost, Decimal.new("0.0004"))

      assert_received {:request_body,
                       %{
                         "messages" => [%{"content" => [%{"text" => prompt} | _]}],
                         "response_format" => rf
                       }}

      assert prompt =~ ~s("logo")
      assert prompt =~ "Only printed logos."

      assert get_in(rf, [
               "json_schema",
               "schema",
               "properties",
               "regions",
               "items",
               "properties",
               "label",
               "enum"
             ]) == ["logo"]
    end

    test "labels must be words" do
      assert {:error, :invalid_labels} =
               PhoenixKitAI.detect_regions(endpoint().uuid, @jpeg, [1, 2])
    end
  end

  describe "describe_image/3 with regions:" do
    test "answers with a description and located things" do
      ep = endpoint()

      stub_json(%{
        "description" => "A cat on a sofa.",
        "regions" => [
          %{
            "label" => "cat",
            "description" => "ginger",
            "box_2d" => [200, 100, 600, 500],
            "image" => 1,
            "confidence" => 0.9
          }
        ]
      })

      assert {:ok,
              %{
                text: "A cat on a sofa.",
                regions: [%{label: "cat", box: %Box{}}],
                dropped_regions: 0
              }} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 prompt: "What is in the photo?",
                 regions: true
               )
    end

    test "without regions: the result keeps its shape" do
      ep = endpoint()
      stub_json(%{"anything" => 1})
      assert {:ok, result} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, json: true)
      refute Map.has_key?(result, :regions)
      assert Map.has_key?(result, :cost)
    end
  end

  describe "extract_text/3 with boxes: true" do
    test "every block carries a box (nil where the model gave an unusable one)" do
      ep = endpoint()

      stub_json(%{
        "text" => "SALE\n50%",
        "blocks" => [
          %{
            "text" => "SALE",
            "kind" => "heading",
            "language" => "en",
            "page" => 1,
            "box_2d" => [0, 0, 200, 1000]
          },
          %{
            "text" => "50%",
            "kind" => "label",
            "language" => "en",
            "page" => 1,
            "box_2d" => [9, 9, 9, 9]
          }
        ],
        "language" => "en",
        "confidence" => 0.95,
        "has_illegible_text" => false
      })

      assert {:ok, %{blocks: [%{text: "SALE", box: %Box{y1: 0.2}}, %{text: "50%", box: nil}]}} =
               PhoenixKitAI.extract_text(ep.uuid, @jpeg, boxes: true)

      assert_received {:request_body, %{"response_format" => rf}}

      assert get_in(rf, [
               "json_schema",
               "schema",
               "properties",
               "blocks",
               "items",
               "properties",
               "box_2d"
             ])
    end

    test "without boxes: blocks have no box key" do
      ep = endpoint()

      stub_json(%{
        "text" => "A",
        "blocks" => [%{"text" => "A", "kind" => "label", "language" => "en", "page" => 1}],
        "language" => "en",
        "confidence" => 1,
        "has_illegible_text" => false
      })

      assert {:ok, %{blocks: [block]}} = PhoenixKitAI.extract_text(ep.uuid, @jpeg)
      refute Map.has_key?(block, :box)
    end
  end

  describe "check_statements/4" do
    test "verdicts per statement with the caller's ids" do
      ep = endpoint()

      stub_json(%{
        "results" => [
          %{
            "n" => 1,
            "verdict" => "supported",
            "evidence" => "red leather",
            "image" => 1,
            "box_2d" => [100, 100, 900, 900]
          },
          %{
            "n" => 2,
            "verdict" => "contradicted",
            "evidence" => "there is one cat",
            "image" => 1,
            "box_2d" => [300, 300, 600, 600]
          }
        ]
      })

      assert {:ok,
              %{
                results: [sofa, cats, lamp],
                counts: %{supported: 1, contradicted: 1, insufficient: 1}
              }} =
               PhoenixKitAI.check_statements(
                 ep.uuid,
                 [{"s1", "The sofa is red leather"}, %{id: "s2", text: "Two cats"}, "A lamp"],
                 @jpeg
               )

      assert %{id: "s1", verdict: :supported, box: %Box{}} = sofa
      assert %{id: "s2", verdict: :contradicted, evidence: "there is one cat"} = cats
      assert %{id: 3, verdict: :insufficient, answered: false} = lamp
    end

    test "statements must be texts" do
      ep = endpoint()
      assert {:error, :empty_input} = PhoenixKitAI.check_statements(ep.uuid, [], @jpeg)

      assert {:error, :invalid_statements} =
               PhoenixKitAI.check_statements(ep.uuid, [:nope], @jpeg)
    end
  end

  describe "run: and step:" do
    test "tag every row — success, refusal — and run_costs totals them" do
      ep = endpoint()
      stub_json(%{"regions" => []})

      assert {:ok, _} =
               PhoenixKitAI.detect_regions(ep.uuid, @jpeg, ["cat"],
                 run: "import-1",
                 step: "locate"
               )

      assert {:ok, _} =
               PhoenixKitAI.describe_image(ep.uuid, @png,
                 json: true,
                 run: "import-1",
                 step: "describe"
               )

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @png, json: true, run: "other-run")

      # A refused call is tagged too.
      {:ok, disabled} = PhoenixKitAI.update_endpoint(ep, %{enabled: false})

      assert {:error, _} =
               PhoenixKitAI.describe_image(disabled.uuid, @png, run: "import-1", step: "describe")

      tagged = Enum.filter(rows(ep), &(&1.metadata["run"] == "import-1"))

      assert Enum.map(tagged, & &1.metadata["step"]) |> Enum.sort() |> Enum.uniq() == [
               "describe",
               "locate"
             ]

      assert {:ok, %{run: "import-1", total: total, by_step: by_step}} =
               PhoenixKitAI.run_costs("import-1")

      assert total.calls == length(tagged)
      assert Decimal.equal?(by_step["locate"].cost, Decimal.new("0.0004"))
      assert by_step["locate"].calls == 1

      assert [_ | _] =
               PhoenixKitAI.list_requests(run: "import-1", step: "locate") |> requests_of()

      assert {:error, :invalid_run} = PhoenixKitAI.run_costs(nil)
    end
  end

  # list_requests/1 answers `{requests, total}`.
  defp requests_of({list, _total}) when is_list(list), do: list

  describe "vision_batch/3" do
    test "a result per item: ok, unparsed and bad input side by side, tagged with one run" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        [%{"content" => [%{"text" => prompt} | _]}] = body["messages"]
        content = if prompt =~ "PROSE", do: "sorry, no json", else: Jason.encode!(%{"ok" => true})

        Req.Test.json(conn, %{
          "model" => "google/gemini-3.8-flash",
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
          "usage" => Map.put(@tokens, "cost", 0.001)
        })
      end)

      items = [
        %{id: :good, images: @jpeg},
        %{id: :prose, images: @png, prompt: "PROSE please"},
        %{id: :bad, images: 12_345}
      ]

      assert {:ok,
              %{
                run: "batch-" <> _ = run,
                items: [good, prose, bad],
                counts: counts,
                stopped: nil,
                cost: cost
              }} =
               PhoenixKitAI.vision_batch(ep.uuid, items, json: true, concurrency: 2)

      assert %{id: :good, status: :ok, result: %{json: %{"ok" => true}}} = good

      assert %{id: :prose, status: :unparsed, result: nil, error: {:no_json_in_response, _}} =
               prose

      assert %{id: :bad, status: :error, error: :invalid_image_input} = bad
      assert counts == %{ok: 1, unparsed: 1, error: 1, skipped: 0}
      assert Decimal.equal?(cost, Decimal.new("0.001"))

      # The unparsed answer was billed: run_costs sees it, the item's cost does not.
      assert {:ok,
              %{
                total: %{calls: 2, errors: 0, unparsed: 1, cost: run_cost},
                by_step: %{"describe_image" => _}
              }} =
               PhoenixKitAI.run_costs(run)

      assert Decimal.equal?(run_cost, Decimal.new("0.002"))
    end

    test "stops starting items once the budget is spent" do
      ep = endpoint()
      stub_json(%{"ok" => true}, "google/gemini-3.8-flash", 0.5)

      items = for i <- 1..5, do: %{id: i, images: @jpeg <> <<i>>}

      assert {:ok, %{stopped: :budget, counts: %{ok: 2, skipped: 3}}} =
               PhoenixKitAI.vision_batch(ep.uuid, items,
                 json: true,
                 concurrency: 1,
                 budget: "1.00",
                 cache: false
               )
    end

    test "stops on a refusal every later item would hit" do
      ep = endpoint()

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{"error" => %{"message" => "Insufficient credits", "code" => 402}})
      end)

      items = for i <- 1..4, do: {i, @jpeg <> <<i>>}

      assert {:ok, %{stopped: {:error, reason}, items: [first | rest]}} =
               PhoenixKitAI.vision_batch(ep.uuid, items, concurrency: 1)

      assert first.status == :error
      assert reason == first.error
      assert Enum.all?(rest, &(&1.status == :skipped))
    end

    test "detect_regions and check_statements run per item" do
      ep = endpoint()
      stub_json(%{"regions" => [], "results" => []})

      assert {:ok, %{items: [%{status: :ok, result: %{regions: []}}]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], verb: :detect_regions, labels: ["cat"])

      assert {:ok, %{items: [%{status: :ok, result: %{counts: %{insufficient: 1}}}]}} =
               PhoenixKitAI.vision_batch(ep.uuid, [%{id: 1, images: @png, statements: ["a cat"]}],
                 verb: :check_statements
               )
    end

    test "rejects an unknown verb, bad items and a bad budget" do
      ep = endpoint()

      assert {:error, {:unsupported_batch_verb, :edit_image}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], verb: :edit_image)

      assert {:error, :invalid_batch_items} = PhoenixKitAI.vision_batch(ep.uuid, :nope)

      assert {:error, {:invalid_budget, _}} =
               PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], budget: 5)

      assert {:ok, %{items: [], counts: %{ok: 0}}} = PhoenixKitAI.vision_batch(ep.uuid, [])
    end
  end
end
