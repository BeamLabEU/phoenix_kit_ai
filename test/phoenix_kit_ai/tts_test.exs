defmodule PhoenixKitAI.TTSTest do
  @moduledoc """
  Tests for the text-to-speech path: `Completion.text_to_speech/3` and the
  public `PhoenixKitAI.speak/3` entry point.

  The decoder is deliberately shape-tolerant — it accepts both the Mistral
  hosted base64-JSON shape (`{"audio_data": "<base64>"}`) and the raw binary
  audio body returned by OpenRouter / OSS vLLM — so both are exercised here.

  Uses `Req.Test` plug stubs to avoid external traffic. Production code is
  unaffected — the setup opts in via
  `Application.put_env(:phoenix_kit_ai, :req_options, plug: ...)`.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Completion

  @audio_bytes <<0xFF, 0xF3, 0x44, 0x00, 0x01, 0x02, 0x03>>

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.TTSTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{
          "api_key" => "sk-test-key",
          "status" => "connected",
          "provider" => "openrouter"
        }
      )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  # Mistral hosted shape: JSON envelope carrying base64 audio.
  defp stub_base64_json(status, bytes) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{"audio_data" => Base.encode64(bytes)}))
    end)
  end

  # OpenRouter / OSS vLLM shape: raw binary audio body.
  defp stub_raw(status, raw_body) do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, status, raw_body)
    end)
  end

  defp stub_json(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "TTS-EP-#{System.unique_integer([:positive])}",
      provider: "mistral",
      model: "voxtral-mini-tts-2603",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  describe "PhoenixKitAI.speak/3 — response shapes" do
    test "decodes the base64-JSON shape (Mistral hosted)" do
      stub_base64_json(200, @audio_bytes)
      ep = endpoint_fixture()

      assert {:ok, %{audio: @audio_bytes, format: "mp3"}} =
               PhoenixKitAI.speak(ep.uuid, "Bonjour", voice_id: "v-123")
    end

    test "decodes the raw-binary shape (OpenRouter / vLLM)" do
      stub_raw(200, @audio_bytes)
      ep = endpoint_fixture()

      assert {:ok, %{audio: @audio_bytes, format: "mp3"}} =
               PhoenixKitAI.speak(ep.uuid, "Bonjour", voice: "casual_male")
    end

    test "honours a non-default response_format" do
      stub_raw(200, @audio_bytes)
      ep = endpoint_fixture()

      assert {:ok, %{audio: @audio_bytes, format: "wav"}} =
               PhoenixKitAI.speak(ep.uuid, "Bonjour", response_format: "wav")
    end

    test "returns only :audio and :format (latency stays internal)" do
      stub_raw(200, @audio_bytes)
      ep = endpoint_fixture()

      assert {:ok, result} = PhoenixKitAI.speak(ep.uuid, "Bonjour")
      assert Map.keys(result) |> Enum.sort() == [:audio, :format]
    end
  end

  describe "PhoenixKitAI.speak/3 — error mapping" do
    test "401 → :invalid_api_key" do
      stub_json(401, %{})
      ep = endpoint_fixture()
      assert {:error, :invalid_api_key} = PhoenixKitAI.speak(ep.uuid, "hi")
    end

    test "402 → :insufficient_credits" do
      stub_json(402, %{})
      ep = endpoint_fixture()
      assert {:error, :insufficient_credits} = PhoenixKitAI.speak(ep.uuid, "hi")
    end

    test "429 → :rate_limited" do
      stub_json(429, %{})
      ep = endpoint_fixture()
      assert {:error, :rate_limited} = PhoenixKitAI.speak(ep.uuid, "hi")
    end

    test "500 → {:api_error, 500}" do
      stub_json(500, %{})
      ep = endpoint_fixture()
      assert {:error, {:api_error, 500}} = PhoenixKitAI.speak(ep.uuid, "hi")
    end

    test "empty body → :invalid_audio_response" do
      stub_raw(200, "")
      ep = endpoint_fixture()
      assert {:error, :invalid_audio_response} = PhoenixKitAI.speak(ep.uuid, "hi")
    end

    test "JSON with un-decodable base64 → :invalid_audio_response" do
      stub_json(200, %{"audio_data" => "!!!not-base64!!!"})
      ep = endpoint_fixture()
      assert {:error, :invalid_audio_response} = PhoenixKitAI.speak(ep.uuid, "hi")
    end
  end

  describe "PhoenixKitAI.speak/3 — validation (no HTTP call)" do
    test "rejects an unknown endpoint" do
      assert {:error, :endpoint_not_found} =
               PhoenixKitAI.speak("019abc12-3456-7def-8901-234567890abc", "hi")
    end

    test "rejects a disabled endpoint" do
      ep = endpoint_fixture(%{enabled: false})
      assert {:error, :endpoint_disabled} = PhoenixKitAI.speak(ep.uuid, "hi")
    end
  end

  describe "PhoenixKitAI.speak/3 — request logging" do
    test "writes a tts success row with audio metadata and captured input" do
      stub_raw(200, @audio_bytes)
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.speak(ep.uuid, "Bonjour, ça va ?", voice: "casual_male")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert %{request_type: "tts", status: "success"} = row
      assert is_integer(row.latency_ms)
      # No token usage for TTS — billing is per-character.
      assert row.input_tokens == 0
      assert row.output_tokens == 0
      assert is_nil(row.cost_cents)

      assert row.metadata["input_chars"] == String.length("Bonjour, ça va ?")
      assert row.metadata["audio_format"] == "mp3"
      assert row.metadata["audio_bytes"] == byte_size(@audio_bytes)
      # Content capture defaults on.
      assert row.metadata["input"] == "Bonjour, ça va ?"
    end

    test "writes a tts error row on failure" do
      stub_json(429, %{})
      ep = endpoint_fixture()

      assert {:error, :rate_limited} = PhoenixKitAI.speak(ep.uuid, "Bonjour")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert %{request_type: "tts", status: "error"} = row
      assert row.metadata["error_reason"] == ":rate_limited"
      assert row.error_message =~ "Rate limited"
    end

    test "redacts input text when capture_request_content is off" do
      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :capture_request_content) end)

      stub_raw(200, @audio_bytes)
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.speak(ep.uuid, "secret text")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert row.metadata["content_redacted"] == true
      refute Map.has_key?(row.metadata, "input")
      # Aggregate (non-PII) metadata is still recorded.
      assert row.metadata["input_chars"] == String.length("secret text")
    end
  end

  describe "Completion.text_to_speech/3 — request body" do
    test "sends model, input, response_format and only the present voice field" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body == %{
                 "model" => "voxtral-mini-tts-2603",
                 "input" => "Bonjour",
                 "response_format" => "mp3",
                 "voice" => "casual_male"
               }

        refute Map.has_key?(body, "voice_id")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"audio_data" => Base.encode64(@audio_bytes)}))
      end)

      ep = endpoint_fixture()

      assert {:ok, %{audio: @audio_bytes}} =
               Completion.text_to_speech(ep, "Bonjour", voice: "casual_male")
    end
  end
end
