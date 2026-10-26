defmodule PhoenixKitAI.RetentionContentKeysTest do
  @moduledoc """
  Every metadata key the request loggers write under the
  `capture_request_content?` gate is in `PhoenixKitAI.Retention.content_keys/0`.

  Each kind of row (chat, tool calls, embeddings, TTS, images, vision; the
  success and the failure) is written twice by one helper with the same
  inputs — capture on, capture off — and every key whose presence or value
  differs must be a content key (or the `content_redacted` marker). That
  also catches a key only whose value is gated, as an image failure's
  `error_reason`. The content step then leaves the captured row as the
  redacted one, apart from the markers.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>

  @tool_call %{
    "id" => "call_1",
    "type" => "function",
    "function" => %{"name" => "get_order", "arguments" => ~s({"number":"A-1"})}
  }

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

    on_exit(fn ->
      PhoenixKitAI.RequestCache.clear()
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_ai, :capture_request_content)
    end)

    :ok
  end

  defp endpoint!(attrs) do
    base = %{
      name: "Keys-EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "google/gemini-2.5-flash",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp chat_answer(message) do
    %{
      "model" => "google/gemini-2.5-flash",
      "choices" => [%{"message" => Map.merge(%{"role" => "assistant"}, message)}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.001}
    }
  end

  defp ok_provider do
    stub(fn conn ->
      case conn.request_path do
        "/api/v1/embeddings" ->
          json(conn, 200, %{
            "data" => [%{"embedding" => [0.1, 0.2]}],
            "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3}
          })

        "/v1/audio/speech" ->
          Plug.Conn.send_resp(conn, 200, @png)

        "/v1/images/generations" ->
          json(conn, 200, %{"data" => [%{"b64_json" => Base.encode64(@png)}]})

        _chat ->
          json(conn, 200, chat_answer(%{"content" => "the answer", "reasoning" => "thinking"}))
      end
    end)
  end

  defp failing_provider do
    stub(fn conn -> json(conn, 500, %{"error" => %{"message" => "boom"}}) end)
  end

  # The same call, captured or not; the row it wrote, as stored.
  defp row(capture?, call) do
    Application.put_env(:phoenix_kit_ai, :capture_request_content, capture?)
    endpoint = call.()

    from(r in Request,
      where: r.endpoint_uuid == ^endpoint.uuid,
      order_by: [desc: r.uuid],
      limit: 1
    )
    |> TestRepo.one!()
  end

  # The rows moved two days back, past the content floor, and cleared.
  defp clear_all_content do
    TestRepo.query!(
      "UPDATE phoenix_kit_ai_requests SET inserted_at = inserted_at - interval '2 days'",
      []
    )

    Retention.run(:manual, %{content: Retention.floor(:content)}, pause_ms: 0)
  end

  defp gated_keys(on, off) do
    keys = Map.keys(on) ++ Map.keys(off)
    keys |> Enum.uniq() |> Enum.filter(&(Map.get(on, &1) != Map.get(off, &1)))
  end

  defp assert_gated_in_content_keys(provider, call, gate?) do
    provider.()
    # one call site, so the debug context (the stack) is the same; reduce,
    # unlike map, adds no frame per element
    [off, on] = Enum.reduce([true, false], [], &[row(&1, call) | &2])

    gated = gated_keys(on.metadata, off.metadata)

    if gate? do
      assert gated != [], "the gate changed nothing — the scenario does not exercise it"
      assert off.metadata["content_redacted"] == true
    else
      assert gated == []
    end

    assert gated -- ["content_redacted" | Retention.content_keys()] == [],
           "gated keys missing from content_keys/0: " <>
             inspect(gated -- ["content_redacted" | Retention.content_keys()])

    # the content step makes the captured row the redacted one
    {:ok, _} = clear_all_content()
    pruned = TestRepo.get!(Request, on.uuid).metadata
    markers = ["content_redacted", "content_pruned_at"]

    assert Map.drop(pruned, markers) ==
             Map.drop(off.metadata, markers ++ Retention.content_keys())
  end

  @scenarios [
    chat: {:ok, :chat},
    chat_tool_calls: {:tools, :chat},
    chat_failure: {:fail, :chat},
    embedding: {:ok, :embedding},
    embedding_failure: {:fail, :embedding},
    tts: {:ok, :tts},
    tts_failure: {:fail, :tts},
    image: {:ok, :image},
    image_failure: {:fail, :image},
    vision: {:ok, :vision},
    vision_failure: {:fail, :vision},
    vision_unparsed: {:ok, :vision_json}
  ]

  for {name, {provider, verb}} <- @scenarios do
    test "#{name}: the gated keys are content keys" do
      provider =
        case unquote(provider) do
          :ok ->
            &ok_provider/0

          :fail ->
            &failing_provider/0

          :tools ->
            fn ->
              stub(&json(&1, 200, chat_answer(%{"content" => nil, "tool_calls" => [@tool_call]})))
            end
        end

      endpoint =
        case unquote(verb) do
          :embedding -> endpoint!(%{model: "openai/text-embedding-3-small"})
          :tts -> endpoint!(%{provider: "mistral", model: "voxtral-mini-tts-2603"})
          :image -> endpoint!(%{provider: "openai", model: "gpt-image-1"})
          _ -> endpoint!(%{})
        end

      call = fn ->
        _ = call(unquote(verb), endpoint)
        endpoint
      end

      # embeddings write nothing under the gate
      assert_gated_in_content_keys(provider, call, unquote(verb) != :embedding)
    end
  end

  defp call(:chat, ep),
    do:
      PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "secret question"}], cache: false)

  defp call(:embedding, ep), do: PhoenixKitAI.embed(ep.uuid, "secret text", cache: false)
  defp call(:tts, ep), do: PhoenixKitAI.speak(ep.uuid, "secret text", cache: false)
  defp call(:image, ep), do: PhoenixKitAI.generate_image(ep.uuid, "a secret cat", cache: false)

  defp call(:vision, ep),
    do: PhoenixKitAI.describe_image(ep.uuid, @jpeg, prompt: "what is secret here?", cache: false)

  defp call(:vision_json, ep),
    do:
      PhoenixKitAI.describe_image(ep.uuid, @jpeg,
        prompt: "what is secret here?",
        json: true,
        cache: false
      )

  test "a row of the old shape: raw_response is a content key and is cleared" do
    at = ~U[2026-01-10 10:00:00Z]

    row =
      TestRepo.insert!(%Request{
        model: "m",
        request_type: "chat",
        status: "success",
        metadata: %{
          "raw_response" => %{"choices" => [%{"message" => %{"content" => "x"}}]},
          "task" => "t"
        },
        inserted_at: at,
        updated_at: at
      })

    assert "raw_response" in Retention.content_keys()
    {:ok, _} = clear_all_content()

    assert %{"task" => "t", "content_pruned_at" => _} =
             metadata = TestRepo.get!(Request, row.uuid).metadata

    refute Map.has_key?(metadata, "raw_response")
  end
end
