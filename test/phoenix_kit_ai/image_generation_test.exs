defmodule PhoenixKitAI.ImageGenerationTest do
  @moduledoc """
  Tests for the image-generation path: `Completion.generate_image/3` and
  the public `PhoenixKitAI.generate_image/3` entry point.

  Unlike TTS, the request/response shape genuinely is the same across
  OpenAI, OpenRouter, and xAI (`{"data": [{"url" | "b64_json", ...}]}`),
  so a single set of tests exercises all of them rather than needing a
  provider-specific describe block.

  Uses `Req.Test` plug stubs to avoid external traffic. Production code is
  unaffected — the setup opts in via
  `Application.put_env(:phoenix_kit_ai, :req_options, plug: ...)`.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Completion

  @image_bytes <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.ImageGenerationTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    :ok
  end

  defp stub_json(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp stub_raw(status, raw_body) do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, status, raw_body)
    end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "Image-EP-#{System.unique_integer([:positive])}",
      provider: "openai",
      model: "gpt-image-1",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  describe "PhoenixKitAI.generate_image/3 — response shapes" do
    test "decodes a single b64_json image" do
      stub_json(200, %{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
      ep = endpoint_fixture()

      assert {:ok, %{images: [%{url: nil, data: @image_bytes}]}} =
               PhoenixKitAI.generate_image(ep.uuid, "a cat on a skateboard")
    end

    test "returns a url image untouched (no auto-download)" do
      stub_json(200, %{"data" => [%{"url" => "https://example.com/cat.png"}]})
      ep = endpoint_fixture()

      assert {:ok, %{images: [%{url: "https://example.com/cat.png", data: nil}]}} =
               PhoenixKitAI.generate_image(ep.uuid, "a cat", response_format: "url")
    end

    test "decodes multiple images (n > 1)" do
      stub_json(200, %{
        "data" => [
          %{"b64_json" => Base.encode64(@image_bytes)},
          %{"url" => "https://example.com/2.png"}
        ]
      })

      ep = endpoint_fixture()

      assert {:ok, %{images: [%{data: @image_bytes}, %{url: "https://example.com/2.png"}]}} =
               PhoenixKitAI.generate_image(ep.uuid, "two cats", n: 2)
    end

    test "returns only :images (latency stays internal)" do
      stub_json(200, %{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
      ep = endpoint_fixture()

      assert {:ok, result} = PhoenixKitAI.generate_image(ep.uuid, "a cat")
      assert Map.keys(result) == [:images]
    end
  end

  describe "PhoenixKitAI.generate_image/3 — error mapping" do
    test "401 -> :invalid_api_key" do
      stub_json(401, %{})
      ep = endpoint_fixture()
      assert {:error, :invalid_api_key} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end

    test "429 -> :rate_limited" do
      stub_json(429, %{})
      ep = endpoint_fixture()
      assert {:error, :rate_limited} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end

    test "500 -> {:api_error, 500}" do
      stub_json(500, %{})
      ep = endpoint_fixture()
      assert {:error, {:api_error, 500}} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end

    test "empty data array -> :invalid_response_format" do
      stub_json(200, %{"data" => []})
      ep = endpoint_fixture()
      assert {:error, :invalid_response_format} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end

    test "missing data key -> :invalid_response_format" do
      stub_json(200, %{"foo" => "bar"})
      ep = endpoint_fixture()
      assert {:error, :invalid_response_format} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end

    test "non-JSON body -> :invalid_json_response" do
      stub_raw(200, "<html>")
      ep = endpoint_fixture()
      assert {:error, :invalid_json_response} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end

    test "un-decodable base64 in an entry decodes to a nil-data entry, not a hard error" do
      stub_json(200, %{"data" => [%{"b64_json" => "!!!not-base64!!!"}]})
      ep = endpoint_fixture()

      assert {:ok, %{images: [%{url: nil, data: nil}]}} =
               PhoenixKitAI.generate_image(ep.uuid, "hi")
    end
  end

  describe "PhoenixKitAI.generate_image/3 — validation (no HTTP call)" do
    test "rejects an unknown endpoint" do
      assert {:error, :endpoint_not_found} =
               PhoenixKitAI.generate_image("019abc12-3456-7def-8901-234567890abc", "hi")
    end

    test "rejects a disabled endpoint" do
      ep = endpoint_fixture(%{enabled: false})
      assert {:error, :endpoint_disabled} = PhoenixKitAI.generate_image(ep.uuid, "hi")
    end
  end

  describe "PhoenixKitAI.generate_image/3 — request logging" do
    test "writes an image success row with count/byte metadata and captured input" do
      stub_json(200, %{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "a cat on a skateboard")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert %{request_type: "image", status: "success"} = row
      assert is_integer(row.latency_ms)
      assert row.input_tokens == 0
      assert row.output_tokens == 0
      assert is_nil(row.cost_cents)

      assert row.metadata["input_chars"] == String.length("a cat on a skateboard")
      assert row.metadata["image_count"] == 1
      assert row.metadata["total_bytes"] == byte_size(@image_bytes)
      assert row.metadata["input"] == "a cat on a skateboard"
    end

    test "url-only response logs zero total_bytes (nothing decoded)" do
      stub_json(200, %{"data" => [%{"url" => "https://example.com/cat.png"}]})
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "a cat")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert row.metadata["total_bytes"] == 0
    end

    test "writes an image error row on failure" do
      stub_json(429, %{})
      ep = endpoint_fixture()

      assert {:error, :rate_limited} = PhoenixKitAI.generate_image(ep.uuid, "a cat")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert %{request_type: "image", status: "error"} = row
      assert row.metadata["error_reason"] == ":rate_limited"
      assert row.error_message =~ "Rate limited"
    end

    test "redacts input prompt when capture_request_content is off" do
      Application.put_env(:phoenix_kit_ai, :capture_request_content, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :capture_request_content) end)

      stub_json(200, %{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
      ep = endpoint_fixture()

      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "a secret prompt")

      row =
        PhoenixKitAI.list_requests()
        |> elem(0)
        |> Enum.find(&(&1.endpoint_uuid == ep.uuid))

      assert row.metadata["content_redacted"] == true
      refute Map.has_key?(row.metadata, "input")
      assert row.metadata["input_chars"] == String.length("a secret prompt")
    end
  end

  describe "PhoenixKitAI.generate_image/3 — default size/quality from the endpoint" do
    test "sends the endpoint's stored image_size/image_quality when the caller passes neither" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["size"] == "1024x1792"
        assert body["quality"] == "hd"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep = endpoint_fixture(%{image_size: "1024x1792", image_quality: "hd"})
      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "a portrait")
    end

    test "an explicit caller :size/:quality overrides the stored default" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["size"] == "1792x1024"
        refute body["quality"] == "hd"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep = endpoint_fixture(%{image_size: "1024x1792", image_quality: "hd"})

      assert {:ok, _} =
               PhoenixKitAI.generate_image(ep.uuid, "a landscape", size: "1792x1024")
    end

    test "no stored default and no caller option omits size/quality entirely" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        refute Map.has_key?(body, "size")
        refute Map.has_key?(body, "quality")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep = endpoint_fixture()
      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "anything")
    end

    test "xAI applies provider_settings aspect_ratio/resolution, not image_size/quality" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["aspect_ratio"] == "16:9"
        assert body["resolution"] == "2k"
        refute Map.has_key?(body, "size")
        refute Map.has_key?(body, "quality")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep =
        endpoint_fixture(%{
          provider: "xai",
          model: "grok-imagine-image",
          # OpenAI-shaped columns must be ignored for xAI defaults.
          image_size: "1024x1024",
          image_quality: "hd",
          provider_settings: %{"aspect_ratio" => "16:9", "resolution" => "2k"}
        })

      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "a landscape")
    end

    test "xAI named connection (xai:personal) still uses aspect_ratio defaults" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["aspect_ratio"] == "9:16"
        refute Map.has_key?(body, "size")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep =
        endpoint_fixture(%{
          provider: "xai:personal",
          model: "grok-imagine-image",
          image_size: "1024x1792",
          provider_settings: %{"aspect_ratio" => "9:16"}
        })

      assert {:ok, _} = PhoenixKitAI.generate_image(ep.uuid, "a portrait")
    end

    test "xAI caller :aspect_ratio overrides the stored default" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["aspect_ratio"] == "1:1"
        assert body["resolution"] == "1k"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep =
        endpoint_fixture(%{
          provider: "xai",
          model: "grok-imagine-image",
          provider_settings: %{"aspect_ratio" => "16:9", "resolution" => "1k"}
        })

      assert {:ok, _} =
               PhoenixKitAI.generate_image(ep.uuid, "a square", aspect_ratio: "1:1")
    end
  end

  describe "Completion.generate_image/3 — request body" do
    test "sends model, prompt, and only the options the caller passed" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body == %{
                 "model" => "gpt-image-1",
                 "prompt" => "a cat on a skateboard",
                 "n" => 2,
                 "size" => "1024x1024"
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep = endpoint_fixture()

      assert {:ok, _} =
               Completion.generate_image(ep, "a cat on a skateboard", n: 2, size: "1024x1024")
    end

    test "sends xAI-specific aspect_ratio/resolution fields" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["aspect_ratio"] == "16:9"
        assert body["resolution"] == "2k"
        refute Map.has_key?(body, "size")
        refute Map.has_key?(body, "quality")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@image_bytes)}]})
        )
      end)

      ep = endpoint_fixture(%{provider: "xai", model: "grok-imagine-image-quality"})

      assert {:ok, _} =
               Completion.generate_image(ep, "a landscape",
                 aspect_ratio: "16:9",
                 resolution: "2k"
               )
    end
  end
end
