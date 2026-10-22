defmodule PhoenixKitAI.GuardTest do
  @moduledoc """
  The call-time check (`authorize/5` → `PhoenixKitAI.Guard`): what a call
  implies it needs, a refusal before any HTTP with its usage row
  (`refused: true`, the task, the reason) that no usage sink receives, the
  `model:` override checked instead of the endpoint's model, `:unknown`
  passing unless only verified models are allowed, `:json` as a warning,
  and `task` / `attribution` / the row uuid on every kind of row and
  result. Capabilities come from declarations on the endpoint or from a
  stubbed OpenRouter catalogue; every provider call is a `Req.Test` stub.
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Budget, Capabilities, Guard, Request}
  alias PhoenixKitAI.Test.{FakeAITasks, FakeUsageSink}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>
  @image_url "data:image/jpeg;base64,/9j/4AAQ"

  @catalogue [
    %{
      "id" => "vendor/vision",
      "architecture" => %{
        "input_modalities" => ["text", "image"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => [
        "tools",
        "response_format",
        "structured_outputs",
        "max_tokens",
        "temperature"
      ]
    },
    %{
      "id" => "vendor/text-only",
      "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
      "supported_parameters" => ["max_tokens", "temperature"]
    }
  ]

  setup do
    PhoenixKitAI.RequestCache.clear()

    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    Application.put_env(:phoenix_kit_ai, :fake_usage_sink_pid, self())
    :ok = ModuleRegistry.register(FakeAITasks)
    :ok = ModuleRegistry.register(FakeUsageSink)

    on_exit(fn ->
      PhoenixKitAI.RequestCache.clear()
      ModuleRegistry.unregister(FakeAITasks)
      ModuleRegistry.unregister(FakeUsageSink)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :fake_usage_sink_pid)
    end)

    :ok
  end

  # An endpoint; `declared` flags are declared on it for its own model.
  defp endpoint(model \\ nil, declared \\ %{}, attrs \\ %{}) do
    model = model || "vendor/model-#{System.unique_integer([:positive])}"

    settings =
      if declared == %{},
        do: %{},
        else: %{"capabilities" => Map.put(declared, "model", model)}

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Guard EP #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: model,
            api_key: "sk-test-key",
            provider_settings: settings
          },
          attrs
        )
      )

    endpoint
  end

  defp text_answer(content) do
    %{
      "model" => "vendor/answer",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
    }
  end

  # The catalogue on GET, `answer` on every POST (whose body is sent to the
  # test process).
  defp stub(answer \\ text_answer("ok"), status \\ 200) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{"data" => @catalogue})

        "POST" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:post, conn.request_path, Jason.decode!(raw)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(answer))
      end
    end)
  end

  # The capability cache, filled from the stubbed catalogue. An OpenRouter
  # endpoint must exist so the catalogue is read.
  defp start_catalogue do
    pid =
      start_supervised!(
        {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
      )

    Req.Test.allow(__MODULE__, self(), pid)
    assert :ok = Capabilities.refresh()
    pid
  end

  defp rows(endpoint),
    do:
      TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid, order_by: r.uuid))

  defp image_message(part),
    do: [%{role: "user", content: [%{type: "text", text: "What is this?"}, part]}]

  defp flush_sink do
    receive do
      {:usage_sink, _} -> flush_sink()
    after
      0 -> :ok
    end
  end

  describe "implied_needs/3" do
    test "chat: image parts with string or atom keys, tools, schema / json" do
      string_part = %{"type" => "image_url", "image_url" => %{"url" => @image_url}}
      atom_part = %{type: "image_url", image_url: %{url: @image_url}}

      assert Guard.implied_needs(:complete, [], image_message(string_part)) == [:vision]
      assert Guard.implied_needs(:complete, [], image_message(atom_part)) == [:vision]

      assert Guard.implied_needs(:complete, [tools: [%{"type" => "function"}], json: true], [
               %{role: "user", content: "hi"}
             ]) == [:tools, :json]

      assert Guard.implied_needs(:complete, [schema: %{"type" => "object"}], []) == [:json]
      assert Guard.implied_needs(:complete, [tools: []], []) == []
    end

    test "vision verbs need images; generation verbs need nothing" do
      assert Guard.implied_needs(:describe_image, []) == [:vision]
      assert Guard.implied_needs(:describe_image, json: true) == [:vision, :json]
      assert Guard.implied_needs(:extract_text, []) == [:vision, :json]
      assert Guard.implied_needs(:compare_images, []) == [:vision, :json]

      for verb <- [:embed, :speak, :generate_image, :edit_image, :process_image],
          do: assert(Guard.implied_needs(verb, []) == [])
    end
  end

  describe "a refused call" do
    test "an image to a model without vision: no HTTP, an error row with the task" do
      stub()
      ep = endpoint(nil, %{"vision" => "no"})
      user = Fixtures.confirmed_user_fixture().uuid

      part = %{"type" => "image_url", "image_url" => %{"url" => @image_url}}

      assert {:error, {:model_unfit, [:vision]}} =
               PhoenixKitAI.complete(ep.uuid, image_message(part),
                 task: "test.plain",
                 user_uuid: user,
                 attribution: %{project: "p1"},
                 source: "GuardTest"
               )

      refute_received {:post, _, _}

      assert [row] = rows(ep)
      assert row.status == "error"
      assert row.request_type == "chat"
      assert row.user_uuid == user
      assert row.error_message =~ "images"
      assert row.cost_cents == nil

      assert %{
               "refused" => true,
               "task" => "test.plain",
               "source" => "GuardTest",
               "attribution" => %{"project" => "p1"},
               "error_reason" => "{:model_unfit, [:vision]}"
             } = row.metadata

      assert is_list(row.metadata["stacktrace"])
    end

    test "the task's own needs count: a tools task on a model without tools" do
      stub()
      ep = endpoint(nil, %{"tools" => "no"})

      assert {:error, {:model_unfit, [:tools]}} =
               PhoenixKitAI.ask(ep.uuid, "hi", task: "test.tools")

      refute_received {:post, _, _}
    end

    test "tools: on the call implies :tools" do
      stub()
      ep = endpoint(nil, %{"tools" => "no"})
      tools = [%{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}]

      assert {:error, {:model_unfit, [:tools]}} = PhoenixKitAI.ask(ep.uuid, "hi", tools: tools)
      refute_received {:post, _, _}
    end

    test "vision verbs: describe_image, extract_text and compare_images" do
      stub()
      ep = endpoint(nil, %{"vision" => "no"})

      assert {:error, {:model_unfit, [:vision]}} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)
      assert {:error, {:model_unfit, [:vision]}} = PhoenixKitAI.extract_text(ep.uuid, @jpeg)

      assert {:error, {:model_unfit, [:vision]}} =
               PhoenixKitAI.compare_images(ep.uuid, @jpeg, @jpeg)

      refute_received {:post, _, _}

      assert [%{request_type: "vision"}, %{request_type: "vision"}, %{request_type: "vision"}] =
               rows(ep)
    end

    test "a generation verb implies nothing: a vision-less model may take images" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"b64_json" => Base.encode64(@png)}]})
      end)

      ep = endpoint(nil, %{"vision" => "no"})
      assert {:ok, %{images: [_]}} = PhoenixKitAI.generate_image(ep.uuid, "a cat")
    end

    test "process_image dry_run still has its fitness checked" do
      ep = endpoint(nil, %{"vision" => "no"})

      assert {:error, {:model_unfit, [:vision]}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance],
                 dry_run: true,
                 task: "test.photo"
               )
    end

    test "a refused row reaches no usage sink; a paid one does" do
      stub()
      ep = endpoint(nil, %{"vision" => "no"})

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: "test.plain")
      assert_received {:usage_sink, %Request{status: "success"}}

      assert {:error, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, task: "test.plain")
      refute_received {:usage_sink, _}
      assert Enum.count(rows(ep), &(&1.metadata["refused"] == true)) == 1
    end

    test "a spend-cap refusal writes a refused row too, which no sink receives" do
      stub(Map.put(text_answer("ok"), "usage", %{"cost" => 1.0}))
      ep = endpoint()
      {:ok, _} = Budget.set_limit(:global, 1_000_000)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "spend it", task: "test.plain")
      flush_sink()

      assert {:error, {:budget_exceeded, :global}} =
               PhoenixKitAI.ask(ep.uuid, "again", task: "test.plain")

      refute_received {:usage_sink, _}

      assert [_paid, %{status: "error", metadata: %{"refused" => true, "task" => "test.plain"}}] =
               rows(ep)
    after
      Budget.set_limit(:global, 0)
    end
  end

  describe "unknown capabilities" do
    test "pass by default and are refused when only verified models are allowed" do
      stub()
      ep = endpoint()

      assert {:ok, _} = PhoenixKitAI.describe_image(ep.uuid, @jpeg)
      assert_received {:post, "/api/v1/chat/completions", _}

      {:ok, _} = PhoenixKit.Settings.update_boolean_setting(Guard.verified_only_setting(), true)

      try do
        assert {:error, {:model_unverified, [:vision]}} =
                 PhoenixKitAI.describe_image(ep.uuid, @jpeg)

        refute_received {:post, _, _}
        # A call that needs nothing is not affected.
        assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi")
      after
        PhoenixKit.Settings.update_boolean_setting(Guard.verified_only_setting(), false)
      end
    end
  end

  describe "with the catalogue" do
    test "describe_image(model:) checks the model it overrides with" do
      stub(text_answer("A cat."))
      vision = endpoint("vendor/vision")
      text = endpoint("vendor/text-only")
      start_catalogue()

      assert {:error, {:model_unfit, [:vision]}} =
               PhoenixKitAI.describe_image(vision.uuid, @jpeg, model: "vendor/text-only")

      refute_received {:post, _, _}
      assert [%{model: "vendor/text-only", metadata: %{"refused" => true}}] = rows(vision)

      assert {:ok, %{text: "A cat."}} =
               PhoenixKitAI.describe_image(text.uuid, @jpeg, model: "vendor/vision")

      assert_received {:post, _, %{"model" => "vendor/vision"}}
    end

    test "chat ignores model: (it sends the endpoint's model), so the endpoint's model is checked" do
      stub()
      vision = endpoint("vendor/vision")
      text = endpoint("vendor/text-only")
      start_catalogue()
      part = %{"type" => "image_url", "image_url" => %{"url" => @image_url}}

      # A vision model named in model: does not let an image reach a text model.
      assert {:error, {:model_unfit, [:vision]}} =
               PhoenixKitAI.complete(text.uuid, image_message(part), model: "vendor/vision")

      refute_received {:post, _, _}
      assert [%{model: "vendor/text-only", metadata: %{"refused" => true}}] = rows(text)

      # A text model named in model: does not refuse a call that goes to a vision model.
      assert {:ok, _} =
               PhoenixKitAI.complete(vision.uuid, image_message(part), model: "vendor/text-only")

      assert_received {:post, _, %{"model" => "vendor/vision"}}
    end

    test ":json is soft: a model without JSON gets the call and the row a warning" do
      stub(text_answer(~s({"a": 1})))
      ep = endpoint("vendor/text-only")
      start_catalogue()

      assert {:ok, %{"json" => %{"a" => 1}}} =
               PhoenixKitAI.ask(ep.uuid, "json please", json: true, task: "test.json")

      assert_received {:post, _, _}
      assert [%{status: "success", metadata: %{"guard_warnings" => ["json"]}}] = rows(ep)
    end
  end

  describe "task, attribution and the row uuid" do
    test "on a chat success, an error, a cache hit and an unparsed JSON answer" do
      stub()
      ep = endpoint()

      assert {:ok, %{"request_uuid" => fresh}} =
               PhoenixKitAI.ask(ep.uuid, "q", task: "test.plain", cache: true)

      # The task is not part of the cache key: another task hits the entry.
      assert {:ok, %{"request_uuid" => hit}} =
               PhoenixKitAI.ask(ep.uuid, "q", task: "test.json", cache: true)

      assert_received {:post, _, _}
      refute_received {:post, _, _}
      assert fresh != hit

      assert %{status: "success", metadata: %{"task" => "test.plain"}} =
               PhoenixKitAI.get_request(fresh)

      assert %{metadata: %{"task" => "test.json", "cached" => true}} =
               PhoenixKitAI.get_request(hit)

      stub(text_answer("not json"))

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.ask(ep.uuid, "q2", json: true, task: "test.plain")

      stub(%{"error" => %{"message" => "boom"}}, 500)
      assert {:error, {:api_error, 500}} = PhoenixKitAI.ask(ep.uuid, "q3", task: "test.plain")

      assert [_fresh, _hit, unparsed, failed] = rows(ep)
      assert %{status: "success", metadata: %{"task" => "test.plain"}} = unparsed
      assert %{status: "error", metadata: %{"task" => "test.plain"}} = failed
      refute failed.metadata["refused"]
    end

    test "a hit whose row cannot be written names no row, never the first call's" do
      stub()
      ep = endpoint()
      # Chat sends the endpoint's model, but a hit's row records model: — one
      # longer than the column takes makes that insert fail.
      long = String.duplicate("m", 150)

      assert {:ok, %{"request_uuid" => first}} =
               PhoenixKitAI.ask(ep.uuid, "q", cache: true, model: long)

      assert is_binary(first)

      capture_log(fn ->
        assert {:ok, hit} = PhoenixKitAI.ask(ep.uuid, "q", cache: true, model: long)
        assert Map.has_key?(hit, "request_uuid")
        assert hit["request_uuid"] == nil
      end)
    end

    test "image verbs record attribution and task; a hit answers with its own row" do
      stub(text_answer("A cat."))
      ep = endpoint(nil, %{"vision" => "yes"})
      opts = [task: "test.plain", attribution: %{project: "p1"}, cache: true]

      assert {:ok, %{request_uuid: fresh}} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, opts)
      assert {:ok, %{request_uuid: hit}} = PhoenixKitAI.describe_image(ep.uuid, @jpeg, opts)
      assert fresh != hit

      for uuid <- [fresh, hit] do
        assert %{
                 request_type: "vision",
                 metadata: %{"task" => "test.plain", "attribution" => %{"project" => "p1"}}
               } = PhoenixKitAI.get_request(uuid)
      end

      assert %{metadata: %{"cached" => true}} = PhoenixKitAI.get_request(hit)
    end

    test "an unparsed vision answer (on_no_json) and a failed one carry the task" do
      stub(text_answer("prose"))
      ep = endpoint()

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg, json: true, task: "test.plain")

      stub(%{}, 500)

      assert {:error, {:api_error, 500}} =
               PhoenixKitAI.extract_text(ep.uuid, @jpeg, task: "test.plain")

      assert [%{status: "success"} = unparsed, %{status: "error"} = failed] = rows(ep)
      assert unparsed.metadata["task"] == "test.plain"
      assert failed.metadata["task"] == "test.plain"
    end

    test "embed and speak results carry their row uuid and the task" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/v1/embeddings" ->
            Req.Test.json(conn, %{"data" => [%{"embedding" => [0.1]}], "usage" => %{}})

          "/api/v1/audio/speech" ->
            conn
            |> Plug.Conn.put_resp_content_type("audio/mpeg")
            |> Plug.Conn.send_resp(200, "ID3audio")
        end
      end)

      ep = endpoint()

      assert {:ok, %{"request_uuid" => embedded}} =
               PhoenixKitAI.embed(ep.uuid, "text", task: "test.plain")

      assert {:ok, %{request_uuid: spoken}} =
               PhoenixKitAI.speak(ep.uuid, "text", task: "test.plain")

      assert %{request_type: "embedding", metadata: %{"task" => "test.plain"}} =
               PhoenixKitAI.get_request(embedded)

      assert %{request_type: "tts", metadata: %{"task" => "test.plain"}} =
               PhoenixKitAI.get_request(spoken)
    end

    test "an unknown task key is logged once and the call goes on with it" do
      stub()
      ep = endpoint()
      key = "nobody.declares-#{System.unique_integer([:positive])}"

      log = capture_log(fn -> assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "hi", task: key) end)
      assert log =~ key
      assert [%{metadata: %{"task" => ^key}}] = rows(ep)
    end

    test "process_image(verify:) passes the task on to its check" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", _} ->
            Req.Test.json(conn, %{"data" => []})

          {"POST", "/api/v1/images"} ->
            Req.Test.json(conn, %{
              "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/png"}]
            })

          {"POST", "/api/v1/chat/completions"} ->
            Req.Test.json(
              conn,
              text_answer(
                Jason.encode!(%{
                  "same_subject" => true,
                  "text_and_logos_preserved" => true,
                  "unwanted_changes" => [],
                  "summary" => "Clean."
                })
              )
            )
        end
      end)

      ep = endpoint("google/gemini-2.5-flash-image")

      assert {:ok, %{request_uuid: edit, verification: %{passed: true, request_uuid: check}}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance],
                 verify: true,
                 task: "test.plain"
               )

      assert %{request_type: "image_edit", metadata: %{"task" => "test.plain"}} =
               PhoenixKitAI.get_request(edit)

      assert %{request_type: "vision", metadata: %{"task" => "test.plain"}} =
               PhoenixKitAI.get_request(check)
    end
  end
end
