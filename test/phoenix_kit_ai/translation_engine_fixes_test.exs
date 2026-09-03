defmodule PhoenixKitAI.TranslationEngineFixesTest do
  @moduledoc """
  HTTP-level coverage for the §9 upstream engine fixes (see the
  2026-09-03 shop-translation-control design doc) that only show up once
  `PhoenixKitAI.Translation.translate_fields/6` actually goes through
  `ask_with_prompt/4` → `complete/3` → the request-logging path — the
  parts `translation_test.exs`'s pure unit tests can't reach.

  Uses the same `Req.Test` plug-stub pattern as `completion_coverage_test.exs`
  (no external traffic; production code is unaffected — opt-in is via
  `Application.put_env(:phoenix_kit_ai, :req_options, plug: ...)`).
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Translation

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    # See completion_coverage_test.exs — registers a connected OpenRouter
    # integration so `validate_endpoint/1` doesn't short-circuit before the
    # stub is ever reached.
    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    :ok
  end

  defp stub_response(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp stub_capturing_body(status, body, test_pid) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:captured_request_body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp stub_transport_error(reason) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, reason) end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "TC-EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "anthropic/claude-3-haiku",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp prompt_fixture(content) do
    {:ok, prompt} =
      PhoenixKitAI.create_prompt(%{
        name: "TC-Prompt-#{System.unique_integer([:positive])}",
        content: content
      })

    prompt
  end

  defp success_payload(content) do
    %{
      "id" => "gen-1",
      "model" => "anthropic/claude-3-haiku",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
    }
  end

  defp latest_request_for(ep) do
    PhoenixKitAI.list_requests()
    |> elem(0)
    |> Enum.find(&(&1.endpoint_uuid == ep.uuid))
  end

  # ==========================================================================
  # §9.1 — dynamic source section, end-to-end
  # ==========================================================================

  describe "§9.1 — {{SourceFields}} round trip" do
    test "the rendered prompt sent over the wire carries one marker per field, alphabetically" do
      ep = endpoint_fixture()

      prompt =
        prompt_fixture("Translate {{SourceLanguage}}->{{TargetLanguage}}:\n\n{{SourceFields}}")

      stub_capturing_body(
        200,
        success_payload("---BODY---\nUn beau widget.\n\n---TITLE---\nWidget"),
        self()
      )

      assert {:ok, %{"title" => "Widget", "body" => "Un beau widget."}} =
               Translation.translate_fields(
                 ep.uuid,
                 prompt.uuid,
                 "en",
                 "fr",
                 %{"title" => "Widget", "body" => "A fine widget."}
               )

      assert_received {:captured_request_body, body}
      user_content = body["messages"] |> List.last() |> Map.get("content")

      assert user_content ==
               "Translate en->fr:\n\n---BODY---\nA fine widget.\n\n---TITLE---\nWidget"
    end
  end

  # ==========================================================================
  # §9.2 — unbound-placeholder guard, wired through ask_with_prompt/4
  # ==========================================================================

  describe "§9.2 — unbound placeholder guard" do
    test "logs a warning and stamps unbound_placeholders on a successful request" do
      ep = endpoint_fixture()

      # `{{campaign_slug}}` is never bound — this is the wiring test for the
      # guard `Prompt.unbound_placeholders/1` implements at the pure-function
      # level (see prompt_test.exs).
      prompt =
        prompt_fixture(
          "Translate {{SourceLanguage}}->{{TargetLanguage}}:\n\n{{SourceFields}}\n\n" <>
            "Campaign: {{campaign_slug}}."
        )

      stub_response(200, success_payload("---TITLE---\nWidget"))

      log =
        capture_log(fn ->
          assert {:ok, %{"title" => "Widget"}} =
                   Translation.translate_fields(
                     ep.uuid,
                     prompt.uuid,
                     "en",
                     "es",
                     %{"title" => "Widget"}
                   )
        end)

      assert log =~ "unbound"
      assert log =~ "{{campaign_slug}}"

      row = latest_request_for(ep)
      assert row.metadata["unbound_placeholders"] == ["{{campaign_slug}}"]
    end

    test "a fully-bound {{SourceFields}}-only prompt records no unbound_placeholders" do
      ep = endpoint_fixture()
      prompt = prompt_fixture("Translate to {{TargetLanguage}}:\n\n{{SourceFields}}")

      stub_response(200, success_payload("---TITLE---\nWidget"))

      assert {:ok, _} =
               Translation.translate_fields(ep.uuid, prompt.uuid, "en", "es", %{
                 "title" => "Widget"
               })

      row = latest_request_for(ep)
      refute Map.has_key?(row.metadata, "unbound_placeholders")
    end
  end

  # ==========================================================================
  # §9.4 — attribution recorded on the failed-request path too
  # ==========================================================================

  describe "§9.4 — attribution on the failure path" do
    test "a failed request still carries the attribution payload in its metadata" do
      ep = endpoint_fixture()

      prompt =
        prompt_fixture("Translate {{SourceLanguage}}->{{TargetLanguage}}: {{SourceFields}}")

      stub_transport_error(:nxdomain)

      assert {:error, {:ai_error, {:connection_error, :nxdomain}}} =
               Translation.translate_fields(
                 ep.uuid,
                 prompt.uuid,
                 "en",
                 "es",
                 %{"title" => "Widget"},
                 attribution: %{"resource_type" => "catalogue_item", "resource_uuid" => "abc-1"}
               )

      row = latest_request_for(ep)
      assert row.status == "error"

      assert row.metadata["attribution"] == %{
               "resource_type" => "catalogue_item",
               "resource_uuid" => "abc-1"
             }
    end
  end

  # ==========================================================================
  # §9.6 — provider error inside a 200 body, end-to-end
  # ==========================================================================

  describe "§9.6 — error-in-body normalisation, end-to-end" do
    test "translate_fields/6 surfaces {:api_error, code} instead of :unexpected_response" do
      ep = endpoint_fixture()

      prompt =
        prompt_fixture("Translate {{SourceLanguage}}->{{TargetLanguage}}: {{SourceFields}}")

      stub_response(200, %{"error" => %{"code" => 504, "message" => "Upstream timeout"}})

      assert {:error, {:ai_error, {:api_error, 504}}} =
               Translation.translate_fields(ep.uuid, prompt.uuid, "en", "es", %{
                 "title" => "Widget"
               })

      # ... and that shape is exactly what TranslateWorker.retryable?/1
      # already classifies as transient — no new rule needed (see
      # translate_worker_test.exs for the classification itself).
      #
      # Note the logged Request row is still "success": the HTTP layer
      # (`PhoenixKitAI.complete/3`) only sees a 200 status, so it logs
      # success and hands the body to `Translation`, which is where the
      # §9.6 normalisation happens — one layer up from request logging.
      row = latest_request_for(ep)
      assert row.status == "success"
    end
  end
end
