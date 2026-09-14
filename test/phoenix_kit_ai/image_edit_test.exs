defmodule PhoenixKitAI.ImageEditTest do
  @moduledoc """
  The image-editing path: `PhoenixKitAI.edit_image/4` through each
  provider adapter.

  Every request body is captured by a `Req.Test` stub and asserted on,
  because the transport differences are the whole point: OpenRouter's
  unified `/images` body with `input_references`, its older
  chat-completions path (`modalities`, `usage.include`), the plain
  chat path other providers get, xAI's JSON `/images/edits` and
  OpenAI's multipart `/images/edits`.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.{Completion, Request}
  alias PhoenixKitAI.Images.ImageModels
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.ImageEditTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    ImageModels.clear()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      ImageModels.clear()
    end)

    :ok
  end

  # Records the JSON body and path in the test process and answers `body`.
  # A GET (the model listing) gets `models` back.
  defp stub_capturing(status, body, models \\ []) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          send(test_pid, {:get, conn.request_path})
          Req.Test.json(conn, %{"data" => models})

        _ ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:request, conn.request_path, Jason.decode!(raw)})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    end)
  end

  # Parses a multipart body (OpenAI's edits endpoint) instead of JSON.
  defp stub_multipart(status, body) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))
      send(test_pid, {:multipart, conn.request_path, conn.body_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "Edit-EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "google/gemini-2.5-flash-image",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp data_url(bytes, type), do: "data:#{type};base64," <> Base.encode64(bytes)

  defp images_payload(entries, usage \\ %{"prompt_tokens" => 1290, "completion_tokens" => 1300}) do
    %{"created" => 1_748_372_400, "data" => entries, "usage" => usage}
  end

  defp chat_payload(message, usage \\ %{"prompt_tokens" => 1290, "completion_tokens" => 1300}) do
    %{
      "id" => "gen-edit-1",
      "model" => "google/gemini-2.5-flash-image",
      "choices" => [%{"message" => Map.merge(%{"role" => "assistant"}, message)}],
      "usage" => usage
    }
  end

  defp inputs,
    do: [%{data: @jpeg, content_type: "image/jpeg"}, %{data: @png, content_type: "image/png"}]

  defp logged_requests do
    TestRepo.all(
      from(r in Request, where: r.request_type == "image_edit", order_by: r.inserted_at)
    )
  end

  describe "OpenRouter — unified Images API (/images)" do
    test "posts prompt, typed options and input_references in order; decodes b64_json + media_type" do
      stub_capturing(
        200,
        images_payload(
          [%{"b64_json" => Base.encode64(@png), "media_type" => "image/png"}],
          %{"prompt_tokens" => 1290, "completion_tokens" => 1300, "cost" => 0.0123}
        )
      )

      ep = endpoint_fixture()

      assert {:ok, %{images: [%{data: @png, url: nil, content_type: "image/png"}], text: nil}} =
               PhoenixKitAI.edit_image(
                 ep.uuid,
                 "Restyle the first photo like the second.",
                 inputs(),
                 aspect_ratio: "4:3",
                 resolution: "2K",
                 background: "transparent",
                 output_format: "png",
                 provider_options: %{"guidance" => 3}
               )

      assert_received {:request, "/api/v1/images", body}
      assert body["model"] == "google/gemini-2.5-flash-image"
      assert body["prompt"] == "Restyle the first photo like the second."
      assert body["aspect_ratio"] == "4:3"
      assert body["resolution"] == "2K"
      assert body["background"] == "transparent"
      assert body["output_format"] == "png"
      assert body["provider"] == %{"options" => %{"guidance" => 3}}
      refute Map.has_key?(body, "messages")

      assert [
               %{"type" => "image_url", "image_url" => %{"url" => first}},
               %{"type" => "image_url", "image_url" => %{"url" => second}}
             ] = body["input_references"]

      assert first == data_url(@jpeg, "image/jpeg")
      assert second == data_url(@png, "image/png")

      # Logged as its own request type, with the provider-reported cost in nanodollars.
      assert [req] = logged_requests()
      assert req.status == "success"
      assert req.model == "google/gemini-2.5-flash-image"
      assert req.input_tokens == 1290
      assert req.output_tokens == 1300
      assert req.cost_cents == 12_300
      assert req.metadata["input_image_count"] == 2
      assert req.metadata["input_bytes"] == byte_size(@jpeg) + byte_size(@png)
      assert req.metadata["output_image_count"] == 1
      assert req.metadata["output_bytes"] == byte_size(@png)
      assert req.metadata["input"] == "Restyle the first photo like the second."
      refute Map.has_key?(req.metadata, "images")
    end

    test "a model override travels in the body and is what gets logged" do
      stub_capturing(200, images_payload([%{"b64_json" => Base.encode64(@png)}]))
      ep = endpoint_fixture()

      assert {:ok, %{model: "openai/gpt-image-1"}} =
               PhoenixKitAI.edit_image(ep.uuid, "Cut out", inputs(), model: "openai/gpt-image-1")

      assert_received {:request, "/api/v1/images", %{"model" => "openai/gpt-image-1"}}
      assert [%{model: "openai/gpt-image-1"}] = logged_requests()
    end

    test "a url entry passes through without bytes; raw bytes are sniffed and inlined" do
      stub_capturing(200, images_payload([%{"url" => "https://cdn.example/out.png"}]))
      ep = endpoint_fixture()

      assert {:ok,
              %{images: [%{data: nil, url: "https://cdn.example/out.png", content_type: nil}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [
                 @jpeg,
                 %{url: "https://example.com/in.jpg"}
               ])

      assert_received {:request, _, body}

      assert [
               %{"image_url" => %{"url" => inlined}},
               %{"image_url" => %{"url" => "https://example.com/in.jpg"}}
             ] =
               body["input_references"]

      assert inlined == data_url(@jpeg, "image/jpeg")
    end

    test "an empty data array is an invalid response; error statuses map through the shared vocabulary" do
      stub_capturing(200, %{"data" => []})
      ep = endpoint_fixture()
      assert {:error, :invalid_response_format} = PhoenixKitAI.edit_image(ep.uuid, "x", inputs())

      stub_capturing(402, %{"error" => %{"message" => "Insufficient credits"}})
      assert {:error, :insufficient_credits} = PhoenixKitAI.edit_image(ep.uuid, "x", inputs())

      assert [%{status: "error"}, %{status: "error", error_message: "Insufficient credits"}] =
               logged_requests()
    end
  end

  describe "chat-completions transport" do
    test "transport: :chat keeps OpenRouter's image fields and decodes message.images" do
      stub_capturing(
        200,
        chat_payload(%{
          "content" => "",
          "images" => [
            %{"type" => "image_url", "image_url" => %{"url" => data_url(@png, "image/png")}}
          ]
        })
      )

      ep = endpoint_fixture()

      assert {:ok, %{images: [%{data: @png, url: nil, content_type: "image/png"}], text: nil}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs(),
                 transport: :chat,
                 aspect_ratio: "4:3"
               )

      assert_received {:request, "/api/v1/chat/completions", body}
      assert body["modalities"] == ["image", "text"]
      assert body["usage"] == %{"include" => true}
      assert body["image_config"] == %{"aspect_ratio" => "4:3"}

      assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "Restyle"}, _, _]}] =
               body["messages"]
    end

    test "accepts an image content part and returns the prose alongside it" do
      stub_capturing(
        200,
        chat_payload(%{
          "content" => [
            %{"type" => "text", "text" => "Here is your kitchen in white oak."},
            %{"type" => "image_url", "image_url" => %{"url" => data_url(@png, "image/png")}}
          ]
        })
      )

      ep =
        endpoint_fixture(%{
          provider: "mistral",
          model: "pixtral-large",
          base_url: "https://api.mistral.ai/v1"
        })

      assert {:ok, %{images: [%{data: @png, content_type: "image/png"}], text: text}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [data_url(@jpeg, "image/jpeg")])

      assert text == "Here is your kitchen in white oak."
      assert [%{metadata: %{"response" => ^text}}] = logged_requests()
    end

    test "prose-only answers surface as no_image_in_response with the prose, and log an error" do
      stub_capturing(200, chat_payload(%{"content" => "I can't modify photos of people."}))
      ep = endpoint_fixture()

      assert {:error, {:no_image_in_response, "I can't modify photos of people."}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs(), transport: :chat)

      assert [req] = logged_requests()
      assert req.status == "error"
      assert req.error_message == "The model returned no image"
      assert req.metadata["error_reason"] =~ "no_image_in_response"
    end

    test "providers without a dedicated adapter use the chat path with neither modalities nor usage.include" do
      stub_capturing(
        200,
        chat_payload(%{"images" => [%{"image_url" => %{"url" => data_url(@png, "image/png")}}]})
      )

      ep =
        endpoint_fixture(%{
          provider: "mistral",
          model: "pixtral-large",
          base_url: "https://api.mistral.ai/v1"
        })

      assert {:ok, %{images: [%{data: @png}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs())

      assert_received {:request, "/v1/chat/completions", body}
      refute Map.has_key?(body, "modalities")
      refute Map.has_key?(body, "usage")
    end
  end

  describe "xAI transport (/images/edits)" do
    test "posts prompt + image list as JSON and decodes b64_json results" do
      stub_capturing(200, %{"data" => [%{"b64_json" => Base.encode64(@png)}]})

      ep =
        endpoint_fixture(%{
          provider: "xai",
          model: "grok-imagine-image-2.0",
          base_url: "https://api.x.ai/v1"
        })

      assert {:ok, %{images: [%{data: @png, url: nil, content_type: "image/png"}], text: nil}} =
               PhoenixKitAI.edit_image(ep.uuid, "Make it night", inputs(),
                 aspect_ratio: "4:3",
                 n: 1
               )

      assert_received {:request, "/v1/images/edits", body}
      assert body["model"] == "grok-imagine-image-2.0"
      assert body["prompt"] == "Make it night"
      assert body["aspect_ratio"] == "4:3"
      assert body["n"] == 1
      refute Map.has_key?(body, "size")

      assert [
               %{"type" => "image_url", "url" => first},
               %{"type" => "image_url", "url" => second}
             ] = body["image"]

      assert first == data_url(@jpeg, "image/jpeg")
      assert second == data_url(@png, "image/png")
    end

    test "a single input is sent as one image object" do
      stub_capturing(200, %{"data" => [%{"url" => "https://x.ai/out.png"}]})

      ep =
        endpoint_fixture(%{
          provider: "xai",
          model: "grok-imagine-image-2.0",
          base_url: "https://api.x.ai/v1"
        })

      assert {:ok, %{images: [%{url: "https://x.ai/out.png", data: nil}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Night", [data_url(@jpeg, "image/jpeg")])

      assert_received {:request, "/v1/images/edits",
                       %{"image" => %{"type" => "image_url", "url" => url}}}

      assert url == data_url(@jpeg, "image/jpeg")
    end
  end

  describe "OpenAI transport (multipart /images/edits)" do
    test "sends the images as files with the prompt and options; aspect_ratio becomes size" do
      stub_multipart(200, %{"data" => [%{"b64_json" => Base.encode64(@png)}]})

      ep =
        endpoint_fixture(%{
          provider: "openai",
          model: "gpt-image-1",
          base_url: "https://api.openai.com/v1"
        })

      assert {:ok, %{images: [%{data: @png, content_type: "image/png"}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "Cut out", inputs(),
                 aspect_ratio: "3:2",
                 background: "transparent",
                 output_format: "png"
               )

      assert_received {:multipart, "/v1/images/edits", params}
      assert params["model"] == "gpt-image-1"
      assert params["prompt"] == "Cut out"
      assert params["size"] == "1536x1024"
      assert params["background"] == "transparent"
      assert params["output_format"] == "png"

      assert [
               %Plug.Upload{content_type: "image/jpeg", path: first},
               %Plug.Upload{content_type: "image/png", path: second}
             ] =
               params["image"]

      assert File.read!(first) == @jpeg
      assert File.read!(second) == @png
    end
  end

  describe "input validation" do
    test "rejects an empty list and malformed entries before any HTTP call" do
      ep = endpoint_fixture()

      assert {:error, :empty_input} = PhoenixKitAI.edit_image(ep.uuid, "Restyle", [])

      assert {:error, :invalid_image_input} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [%{foo: 1}])

      assert {:error, :invalid_image_input} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", ["not a url"])

      assert {:error, :invalid_image_input} =
               PhoenixKitAI.edit_image(ep.uuid, "Restyle", [%{data: "plain text"}])

      refute_received {:request, _, _}
      assert logged_requests() == []
    end

    test "endpoint problems short-circuit like every other verb" do
      assert {:error, :endpoint_not_found} =
               PhoenixKitAI.edit_image(Ecto.UUID.generate(), "Restyle", inputs())

      ep = endpoint_fixture(%{enabled: false})
      assert {:error, :endpoint_disabled} = PhoenixKitAI.edit_image(ep.uuid, "Restyle", inputs())
    end
  end

  describe "Completion.decode_image_url/1" do
    test "splits base64 data URLs into bytes and MIME type" do
      assert %{data: @png, url: nil, content_type: "image/png"} =
               Completion.decode_image_url(data_url(@png, "image/png"))
    end

    test "tolerates a missing MIME type and malformed base64" do
      assert %{data: @png, content_type: nil} =
               Completion.decode_image_url("data:;base64," <> Base.encode64(@png))

      assert %{data: nil, url: nil} = Completion.decode_image_url("data:image/png;base64,%%%")
    end

    test "passes http URLs through" do
      assert %{data: nil, url: "https://x/y.png", content_type: nil} =
               Completion.decode_image_url("https://x/y.png")
    end
  end
end
