defmodule PhoenixKitAI.ImagesTest do
  @moduledoc """
  The provider-neutral image layer: operations → one prompt, options
  fitted to the model, `process/4`, `describe/3` and `compare/4`, with
  every provider call stubbed and its body asserted.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Images, Provider, Request}
  alias PhoenixKitAI.Images.{ImageModel, ImageModels, Operations}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>

  @listing [
    %{
      "id" => "google/gemini-2.5-flash-image",
      "name" => "Nano Banana",
      "supported_parameters" => %{
        "aspect_ratio" => %{"type" => "enum", "values" => ["1:1", "4:3", "3:4"]},
        "n" => %{"type" => "range", "min" => 1, "max" => 1},
        "input_references" => %{"type" => "range", "min" => 0, "max" => 3}
      }
    },
    %{
      "id" => "openai/gpt-image-1",
      "name" => "GPT Image 1",
      "supported_parameters" => %{
        "aspect_ratio" => %{"type" => "enum", "values" => ["1:1", "3:2", "2:3", "auto"]},
        "quality" => %{"type" => "enum", "values" => ["auto", "low", "medium", "high"]},
        "background" => %{"type" => "enum", "values" => ["auto", "transparent", "opaque"]},
        "output_format" => %{"type" => "enum", "values" => ["png", "jpeg", "webp"]},
        "seed" => %{"type" => "boolean"},
        "input_references" => %{"type" => "range", "min" => 0, "max" => 16}
      },
      "endpoints" => [%{"pricing" => %{"output_image" => "0.00004"}}]
    }
  ]

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.ImagesTest},
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
      Application.delete_env(:phoenix_kit_ai, :image_operations)
      Application.delete_env(:phoenix_kit_ai, :provider_adapters)
      ImageModels.clear()
    end)

    :ok
  end

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "Images-EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "google/gemini-2.5-flash-image",
      api_key: "sk-test-key"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  # GET → the model listing; POST → captured body, canned answer.
  defp stub(answer) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "GET" ->
          send(test_pid, {:get, conn.request_path})
          Req.Test.json(conn, %{"data" => @listing})

        _ ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:post, conn.request_path, Jason.decode!(raw)})
          Req.Test.json(conn, answer)
      end
    end)
  end

  defp image_answer,
    do: %{"data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/png"}]}

  defp chat_image_answer do
    %{
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "images" => [
              %{"image_url" => %{"url" => "data:image/png;base64," <> Base.encode64(@png)}}
            ]
          }
        }
      ]
    }
  end

  defp chat_answer(content) do
    %{
      "model" => "google/gemini-2.5-flash",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 300, "completion_tokens" => 40, "cost" => 0.0005}
    }
  end

  describe "Operations" do
    test "normalises atoms, tuples, strings and custom text; fills defaults; refuses the unknown" do
      assert {:ok,
              [
                {:enhance, %{}},
                {:clean_background, %{color: "white"}},
                {:relight, %{light: :night}},
                {:instruction, %{text: "Add a shadow"}},
                {:instruction, %{text: "Custom"}}
              ]} =
               Operations.normalize([
                 :enhance,
                 :clean_background,
                 {:relight, light: :night},
                 "Add a shadow",
                 {:custom, "Custom"}
               ])

      assert {:error, {:unknown_operation, :teleport}} = Operations.normalize([:teleport])

      assert {:error, {:missing_parameter, :remove_objects, :what}} =
               Operations.normalize([:remove_objects])

      assert {:error, {:missing_parameter, :instruction, :text}} = Operations.normalize([""])
    end

    test "renders templates with parameters and presets" do
      assert {:ok, text} = Operations.render(:clean_background, %{color: "light grey"})
      assert text =~ "light grey studio backdrop"

      assert {:ok, night} = Operations.render(:relight, %{light: :night})
      assert night =~ "night: dark outside"

      assert {:ok, custom} = Operations.render(:relight, %{light: "candlelight only"})
      assert custom =~ "candlelight only"

      assert {:ok, fallback} = Operations.render(:remove_background, %{}, fallback: true)
      assert fallback =~ "pure white background"
    end

    test "implied options merge in order, and a parameter that is an option overrides the default" do
      {:ok, pairs} = Operations.normalize([:remove_background, {:upscale, resolution: "4K"}])

      assert Operations.options(pairs) == %{
               background: "transparent",
               output_format: "png",
               resolution: "4K"
             }
    end

    test "a host adds operations through config" do
      Application.put_env(:phoenix_kit_ai, :image_operations, %{
        "product_shot" => %{
          "prompt" => "Place the product on a seamless {{color}} sweep.",
          "params" => ["color"],
          "options" => %{"aspect_ratio" => "1:1"}
        }
      })

      assert {:ok, [{:product_shot, %{color: "white"}}]} =
               Operations.normalize([{:product_shot, color: "white"}])

      assert {:ok, "Place the product on a seamless white sweep."} =
               Operations.render(:product_shot, %{color: "white"})

      assert :product_shot in Operations.names()
    end

    test "a saved prompt named after the operation overrides the wording" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Image op enhance",
          content: "Make it pop, but keep {{what}} intact.",
          variables: ["what"]
        })

      assert prompt.slug == "image-op-enhance"

      assert {:ok, "Make it pop, but keep {{what}} intact."} = Operations.render(:enhance, %{})
      assert {:ok, text} = Operations.render(:enhance, %{}, prompt_overrides: false)
      assert text =~ "exposure"
    end
  end

  describe "build_prompt/2" do
    test "one operation reads as a sentence, several as a numbered list, then the preservation and closing lines" do
      assert {:ok, single} = Images.build_prompt([:enhance])
      assert single =~ "Improve the photograph's exposure"
      refute single =~ ~r/^1\. /m
      assert single =~ "Keep the subject itself"
      assert single =~ "No added text or watermark."

      assert {:ok, many} =
               Images.build_prompt([:remove_reflections, {:clean_background, color: "white"}],
                 preserve: :scene,
                 finish: false
               )

      assert many =~ "1. Remove glare"
      assert many =~ "2. Replace the background with a clean, plain, evenly lit white"
      assert many =~ "Keep the scene's geometry"
      refute many =~ "No added text"

      assert {:ok, custom} =
               Images.build_prompt([:enhance], preserve: "Keep the cat.", finish: "Done.")

      assert custom =~ "Keep the cat.\n\nDone."

      assert {:ok, bare} = Images.build_prompt(["Just this"], preserve: false, finish: false)
      assert bare == "Just this"
    end

    test "an operation whose implied option was dropped uses its fallback wording" do
      assert {:ok, text} =
               Images.build_prompt([:remove_background],
                 warnings: [{:dropped_option, :background, "transparent"}]
               )

      assert text =~ "pure white background"
      refute text =~ "fully transparent"
    end
  end

  describe "ImageModel" do
    test "parses OpenRouter's typed parameter listing" do
      [_, gpt] = Enum.map(@listing, &ImageModel.from_openrouter/1)

      assert %ImageModel{
               id: "openai/gpt-image-1",
               provider: "openai",
               pricing: %{"output_image" => "0.00004"}
             } = gpt

      assert ImageModel.supports?(gpt, :background)
      assert ImageModel.allows?(gpt, :background, "transparent")
      refute ImageModel.allows?(gpt, :background, "green")
      assert ImageModel.allows?(gpt, :seed, 42)
      refute ImageModel.allows?(gpt, :resolution, "2K")
      assert ImageModel.values(gpt, :quality) == ["auto", "low", "medium", "high"]
      assert ImageModel.max_references(gpt) == 16
      refute ImageModel.supports?(nil, :background)
    end
  end

  describe "fit_options/4" do
    test "drops what the model does not list, in canonical order, and refuses under strict" do
      [gemini, _] = Enum.map(@listing, &ImageModel.from_openrouter/1)

      options = %{
        aspect_ratio: "4:3",
        background: "transparent",
        output_format: "png",
        model: "x",
        provider_options: %{"a" => 1}
      }

      # The listing is the truth: an option the adapter could send but the
      # model does not list is dropped as well (background is in
      # OpenRouter's typed set, Gemini does not take it).
      assert {:ok, fitted, warnings} =
               Images.fit_options(options, gemini, [:aspect_ratio, :background], false)

      assert fitted == %{aspect_ratio: "4:3", model: "x", provider_options: %{"a" => 1}}

      assert warnings == [
               {:dropped_option, :background, "transparent"},
               {:dropped_option, :output_format, "png"}
             ]

      assert {:error, {:unsupported_option, :background, "transparent"}} =
               Images.fit_options(options, gemini, [:aspect_ratio], true)

      # A key the adapter does not send is dropped even when the model lists it.
      [_, gpt] = Enum.map(@listing, &ImageModel.from_openrouter/1)

      assert {:ok, %{aspect_ratio: "1:1"}, [{:dropped_option, :background, "transparent"}]} =
               Images.fit_options(
                 %{aspect_ratio: "1:1", background: "transparent"},
                 gpt,
                 [:aspect_ratio],
                 false
               )

      # A value the model rejects is dropped too; no listing → the adapter's list decides.
      assert {:ok, %{}, [{:dropped_option, :aspect_ratio, "21:9"}]} =
               Images.fit_options(%{aspect_ratio: "21:9"}, gemini, [], false)

      assert {:ok, %{aspect_ratio: "21:9"}, [{:dropped_option, :quality, "high"}]} =
               Images.fit_options(
                 %{aspect_ratio: "21:9", quality: "high"},
                 nil,
                 [:aspect_ratio],
                 false
               )
    end
  end

  describe "process_image/4" do
    test "composes the prompt, fits options to the model, posts once and logs operations + warnings" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:ok,
              %{
                images: [%{data: @png, content_type: "image/png"}],
                prompt: prompt,
                operations: [:remove_reflections, :remove_background],
                warnings: warnings,
                model: "google/gemini-2.5-flash-image"
              }} =
               PhoenixKitAI.process_image(
                 ep.uuid,
                 [@jpeg],
                 [:remove_reflections, :remove_background],
                 aspect_ratio: "4:3"
               )

      # Gemini lists no `background`, so the cutout fell back to white and the option was dropped.
      assert warnings == [
               {:dropped_option, :background, "transparent"},
               {:dropped_option, :output_format, "png"}
             ]

      assert prompt =~ "1. Remove glare"

      assert prompt =~
               "2. Cut the subject out cleanly along its true edges and place it on a plain, pure white background."

      assert prompt =~ "Keep the subject itself"

      assert_received {:get, "/api/v1/images/models"}
      assert_received {:post, "/api/v1/images", body}
      assert body["prompt"] == prompt
      assert body["aspect_ratio"] == "4:3"
      refute Map.has_key?(body, "background")

      assert [%{"image_url" => %{"url" => "data:image/jpeg;base64," <> _}}] =
               body["input_references"]

      assert [req] = TestRepo.all(from(r in Request, where: r.request_type == "image_edit"))
      assert req.metadata["operations"] == ["remove_reflections", "remove_background"]
      assert req.metadata["warnings"] =~ "dropped_option"
    end

    test "a model override that lists the option keeps it, with the transparent wording" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:ok, %{warnings: [], prompt: prompt, model: "openai/gpt-image-1"}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:remove_background],
                 model: "openai/gpt-image-1"
               )

      assert prompt =~ "fully transparent"

      assert_received {:post, "/api/v1/images",
                       %{
                         "model" => "openai/gpt-image-1",
                         "background" => "transparent",
                         "output_format" => "png"
                       }}
    end

    test "a chat-completions edit drops the options it cannot send and uses the fallback wording" do
      stub(chat_image_answer())

      ep =
        endpoint_fixture(%{
          provider: "mistral",
          model: "pixtral-large",
          base_url: "https://api.mistral.ai/v1",
          image_size: "1024x1024"
        })

      assert {:ok, %{warnings: warnings, prompt: prompt}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:remove_background],
                 aspect_ratio: "4:3"
               )

      # The stored image_size is not an option this edit sends, so it is left
      # out quietly; the cutout's implied options are dropped out loud.
      assert warnings == [
               {:dropped_option, :background, "transparent"},
               {:dropped_option, :output_format, "png"}
             ]

      assert prompt =~ "pure white background"
      refute prompt =~ "transparent"

      assert_received {:post, "/v1/chat/completions", body}
      assert body["image_config"] == %{"aspect_ratio" => "4:3"}
      refute_received {:get, _}
    end

    test "OpenRouter's chat transport drops what only its /images API takes, whatever the listing says" do
      stub(chat_image_answer())
      ep = endpoint_fixture()

      assert {:ok, %{warnings: warnings, prompt: prompt}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:remove_background],
                 model: "openai/gpt-image-1",
                 transport: :chat
               )

      assert warnings == [
               {:dropped_option, :background, "transparent"},
               {:dropped_option, :output_format, "png"}
             ]

      assert prompt =~ "pure white background"

      assert_received {:post, "/api/v1/chat/completions", body}
      assert body["modalities"] == ["image", "text"]
      refute Map.has_key?(body, "background")
    end

    test "strict mode refuses an unsupported option before any request" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:error, {:unsupported_option, :background, "transparent"}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:remove_background], strict: true)

      refute_received {:post, _, _}
      assert [] = TestRepo.all(from(r in Request, where: r.request_type == "image_edit"))
    end

    test "restyle needs a reference image; unknown operations never reach the provider" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:error, :reference_image_required} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:restyle])

      assert {:error, {:unknown_operation, :nope}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:nope])

      refute_received {:post, _, _}

      assert {:ok, %{prompt: prompt}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg, @png], [:restyle], preserve: :scene)

      assert prompt =~ "Image 1 is the subject."
      assert_received {:post, "/api/v1/images", %{"input_references" => [_, _]}}
    end

    test "works the same on a provider without a listing (xAI): adapter options decide" do
      stub(image_answer())

      ep =
        endpoint_fixture(%{
          provider: "xai",
          model: "grok-imagine-image-2.0",
          base_url: "https://api.x.ai/v1"
        })

      assert {:ok, %{warnings: warnings}} =
               PhoenixKitAI.process_image(
                 ep.uuid,
                 [@jpeg],
                 [:remove_background, {:upscale, resolution: "2K"}],
                 aspect_ratio: "4:3"
               )

      assert {:dropped_option, :background, "transparent"} in warnings
      refute_received {:get, _}
      assert_received {:post, "/v1/images/edits", body}
      assert body["aspect_ratio"] == "4:3"
      assert body["resolution"] == "2K"
      refute Map.has_key?(body, "background")
    end
  end

  describe "describe_image/3 and compare_images/4" do
    test "asks with the images attached, requests JSON per schema, parses it and logs a vision row" do
      stub(chat_answer(~s(```json\n{"brand": "Snickers", "flavour": "peanut"}\n```)))
      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      schema = %{"type" => "object", "properties" => %{"brand" => %{"type" => "string"}}}

      assert {:ok,
              %{json: %{"brand" => "Snickers"}, text: text, model: "google/gemini-2.5-flash"}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg,
                 prompt: "Read the label.",
                 schema: schema
               )

      assert text =~ "Snickers"
      assert_received {:post, "/api/v1/chat/completions", body}

      assert %{"type" => "json_schema", "json_schema" => %{"schema" => ^schema, "strict" => true}} =
               body["response_format"]

      assert [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => question}, %{"type" => "image_url"}]
               }
             ] = body["messages"]

      assert question =~ "Read the label."
      assert question =~ "JSON object matching this JSON Schema"
      assert question =~ ~s("brand")

      assert [%{request_type: "vision", cost_cents: 500, input_tokens: 300}] =
               TestRepo.all(from(r in Request, where: r.request_type == "vision"))
    end

    test "free text needs no response_format; a non-JSON answer to a JSON request is an error" do
      stub(chat_answer("A chocolate bar on a desk."))
      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:ok, %{text: "A chocolate bar on a desk.", json: nil}} =
               PhoenixKitAI.describe_image(ep.uuid, [@jpeg])

      assert_received {:post, _, body}
      refute Map.has_key?(body, "response_format")

      assert {:error, {:no_json_in_response, "A chocolate bar on a desk."}} =
               PhoenixKitAI.describe_image(ep.uuid, [@jpeg], json: true)
    end

    test "a model that rejects response_format gets one retry without it" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:post, conn.request_path, body})

        if Map.has_key?(body, "response_format") do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            400,
            Jason.encode!(%{"error" => %{"message" => "response_format is not supported"}})
          )
        else
          Req.Test.json(conn, chat_answer(~s({"brand": "Snickers"})))
        end
      end)

      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash-image"})

      assert {:ok, %{json: %{"brand" => "Snickers"}}} =
               PhoenixKitAI.describe_image(ep.uuid, [@jpeg], json: true)

      assert_received {:post, "/api/v1/chat/completions", %{"response_format" => _}}
      assert_received {:post, "/api/v1/chat/completions", second}
      refute Map.has_key?(second, "response_format")
    end

    test "extract_text transcribes with the OCR schema, pulls named fields and logs a vision row" do
      answer = %{
        "text" => "SNICKERS\nBest before 2027-03-01\n5000159461122",
        "blocks" => [
          %{"text" => "SNICKERS", "kind" => "heading", "language" => "en"},
          %{"text" => "Best before 2027-03-01", "kind" => "label", "language" => "en"},
          %{"text" => "5000159461122", "kind" => "label", "language" => "und"}
        ],
        "language" => "en",
        "confidence" => 0.93,
        "has_illegible_text" => true,
        "fields" => %{"ean" => "5000159461122", "best_before" => "2027-03-01", "extra" => "x"}
      }

      stub(chat_answer(Jason.encode!(answer)))
      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:ok,
              %{
                text: "SNICKERS\nBest before 2027-03-01\n5000159461122",
                blocks: [%{"kind" => "heading"} | _],
                language: "en",
                confidence: 0.93,
                has_illegible_text: true,
                fields: %{"ean" => "5000159461122", "best_before" => "2027-03-01"} = fields,
                model: "google/gemini-2.5-flash"
              }} =
               PhoenixKitAI.extract_text(ep.uuid, @jpeg,
                 fields: %{ean: "the barcode digits", best_before: "expiry date as YYYY-MM-DD"},
                 language: "en",
                 layout: :markdown
               )

      refute Map.has_key?(fields, "extra")
      assert_received {:post, "/api/v1/chat/completions", body}

      assert %{"json_schema" => %{"schema" => schema, "strict" => true}} = body["response_format"]
      assert %{"fields" => %{"required" => required}} = schema["properties"]
      assert Enum.sort(required) == ["best_before", "ean"]

      assert [%{"content" => [%{"text" => question}, %{"type" => "image_url"}]}] =
               body["messages"]

      assert question =~ "Transcribe all text"
      assert question =~ "never invent plausible wording"
      assert question =~ "Markdown"
      assert question =~ "most likely in en"
      assert question =~ "- ean: the barcode digits"

      assert [%{request_type: "vision", metadata: %{"language" => "en"}}] =
               TestRepo.all(from(r in Request, where: r.request_type == "vision"))
    end

    test "extract_text reads several images as pages and tolerates an empty page" do
      stub(
        chat_answer(
          Jason.encode!(%{"text" => "", "blocks" => [], "language" => "und", "confidence" => 0})
        )
      )

      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:ok, %{text: "", blocks: [], fields: %{}, has_illegible_text: false}} =
               PhoenixKitAI.extract_text(ep.uuid, [@jpeg, @jpeg])

      assert_received {:post, _, body}
      assert [%{"content" => [%{"text" => question}, _, _]}] = body["messages"]
      assert question =~ "2 images are pages of one document"
      refute question =~ "fields"
    end

    test "compare turns the fixed-schema answer into a verdict" do
      stub(
        chat_answer(
          Jason.encode!(%{
            "same_subject" => true,
            "text_and_logos_preserved" => false,
            "unwanted_changes" => ["logo blurred"],
            "summary" => "Background replaced."
          })
        )
      )

      ep = endpoint_fixture(%{model: "google/gemini-2.5-flash"})

      assert {:ok,
              %{
                passed: false,
                same_subject: true,
                text_and_logos_preserved: false,
                unwanted_changes: ["logo blurred"],
                summary: "Background replaced."
              }} =
               PhoenixKitAI.compare_images(ep.uuid, @jpeg, @png, intent: "clean background")

      assert_received {:post, _, body}
      [%{"content" => [%{"text" => prompt}, _, _]}] = body["messages"]
      assert prompt =~ "the requested edit was: clean background"
    end
  end

  describe "image_models/2 and the cache" do
    test "lists once per base URL until refreshed; providers without a listing say so" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:ok,
              [
                %ImageModel{id: "google/gemini-2.5-flash-image"},
                %ImageModel{id: "openai/gpt-image-1"}
              ]} = PhoenixKitAI.image_models(ep.uuid)

      assert {:ok, _} = PhoenixKitAI.image_models(ep.uuid)
      assert_received {:get, "/api/v1/images/models"}
      refute_received {:get, _}

      assert {:ok, _} = PhoenixKitAI.image_models(ep.uuid, refresh: true)
      assert_received {:get, "/api/v1/images/models"}

      assert %ImageModel{id: "google/gemini-2.5-flash-image"} = PhoenixKitAI.image_model(ep.uuid)

      xai =
        endpoint_fixture(%{
          provider: "xai",
          model: "grok-imagine-image-2.0",
          base_url: "https://api.x.ai/v1"
        })

      assert {:error, :not_supported} = PhoenixKitAI.image_models(xai.uuid)
      assert PhoenixKitAI.image_model(xai.uuid) == nil

      assert PhoenixKitAI.image_options(xai.uuid) == [
               :n,
               :response_format,
               :aspect_ratio,
               :resolution
             ]
    end
  end

  describe "Provider resolution" do
    test "picks the adapter by base provider key, with a host override map" do
      assert Provider.for_endpoint(%{provider: "openrouter"}) == PhoenixKitAI.Providers.OpenRouter

      assert Provider.for_endpoint(%{provider: "openrouter:custom"}) ==
               PhoenixKitAI.Providers.OpenRouter

      assert Provider.for_endpoint(%{provider: "xai"}) == PhoenixKitAI.Providers.XAI
      assert Provider.for_endpoint(%{provider: "openai"}) == PhoenixKitAI.Providers.OpenAI

      assert Provider.for_endpoint(%{provider: "mistral"}) ==
               PhoenixKitAI.Providers.OpenAICompatible

      assert Provider.for_endpoint(%{provider: nil}) == PhoenixKitAI.Providers.OpenAICompatible

      Application.put_env(:phoenix_kit_ai, :provider_adapters, %{
        "xai" => FakeXai,
        fal: FakeFalAdapter
      })

      assert Provider.for_provider("fal") == FakeFalAdapter
      assert Provider.for_endpoint(%{provider: "xai"}) == FakeXai
    end
  end

  describe "round two: limits, conflicts, masks, dry runs, outputs" do
    test "two background treatments conflict; a transparent cutout corrects a jpeg request" do
      assert {:error, {:conflicting_operations, :clean_background, :blur_background}} =
               Operations.normalize([:clean_background, :blur_background])

      stub(image_answer())
      ep = endpoint_fixture()

      assert {:ok, %{warnings: warnings, prompt: prompt}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:remove_background],
                 model: "openai/gpt-image-1",
                 output_format: "jpeg"
               )

      assert {:adjusted_option, :output_format, "jpeg", "png"} in warnings
      assert prompt =~ "fully transparent"

      assert_received {:post, "/api/v1/images",
                       %{"background" => "transparent", "output_format" => "png"}}
    end

    test "dry_run returns the plan without a request or a usage row" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:ok,
              %{
                dry_run: true,
                prompt: prompt,
                options: %{aspect_ratio: "4:3"},
                warnings: [],
                model: model
              }} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance],
                 aspect_ratio: "4:3",
                 dry_run: true
               )

      assert prompt =~ "Improve the photograph"
      assert model == "google/gemini-2.5-flash-image"
      refute_received {:post, _, _}
      assert [] = TestRepo.all(from(r in Request, where: r.request_type == "image_edit"))
    end

    test "oversized inputs, unsafe urls and unknown models are handled before any request" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:error, {:image_too_large, 20, 10}} =
               PhoenixKitAI.process_image(
                 ep.uuid,
                 [String.duplicate(<<0xFF, 0xD8, 0xFF, 0xE0>>, 5)],
                 [:enhance],
                 max_input_bytes: 10
               )

      assert {:error, {:unsafe_url, "http://127.0.0.1/secret.png"}} =
               PhoenixKitAI.process_image(ep.uuid, [%{url: "http://127.0.0.1/secret.png"}], [
                 :enhance
               ])

      assert {:error, {:unsafe_url, "http://10.0.0.5/x.png"}} =
               PhoenixKitAI.edit_image(ep.uuid, "x", ["http://10.0.0.5/x.png"])

      refute_received {:post, _, _}

      # A model the listing does not know is a warning, not a refusal.
      assert {:ok, %{warnings: [{:model_not_listed, "vendor/new-model"} | _]}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance], model: "vendor/new-model")
    end

    test "a published reference maximum is enforced even when not strict" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:error, {:too_many_images, 4, 3}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg, @png, @jpeg, @png], [:enhance])

      refute_received {:post, _, _}
    end

    test "a mask is sent by the OpenAI adapter and dropped with a warning elsewhere" do
      stub(image_answer())
      ep = endpoint_fixture()

      assert {:ok, %{warnings: warnings}} =
               PhoenixKitAI.process_image(
                 ep.uuid,
                 [@jpeg],
                 [{:remove_objects, what: "the price sticker"}],
                 mask: @png
               )

      assert Enum.any?(warnings, &match?({:dropped_option, :mask, _}, &1))
      assert_received {:post, "/api/v1/images", body}
      refute Map.has_key?(body, "mask")

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))
        send(test_pid, {:multipart, conn.request_path, conn.body_params})
        Req.Test.json(conn, image_answer())
      end)

      openai =
        endpoint_fixture(%{
          provider: "openai",
          model: "gpt-image-1",
          base_url: "https://api.openai.com/v1"
        })

      assert {:ok, %{warnings: []}} =
               PhoenixKitAI.process_image(
                 openai.uuid,
                 [@jpeg],
                 [{:remove_objects, what: "the sticker"}],
                 mask: @png
               )

      assert_received {:multipart, "/v1/images/edits",
                       %{"mask" => %Plug.Upload{content_type: "image/png"}}}
    end

    test "content-policy refusals get their own error, and failures log latency + provider" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{"message" => "Your request was rejected by the safety system"}
          })
        )
      end)

      ep = endpoint_fixture()

      assert {:error, {:content_policy, "Your request was rejected by the safety system"}} =
               PhoenixKitAI.edit_image(ep.uuid, "x", [@jpeg],
                 model: "openai/gpt-image-1",
                 idempotency_key: "job-1"
               )

      assert [
               %{
                 status: "error",
                 latency_ms: latency,
                 model: "openai/gpt-image-1",
                 metadata: meta
               }
             ] =
               TestRepo.all(from(r in Request, where: r.request_type == "image_edit"))

      assert is_integer(latency)
      assert meta["provider"] == "openrouter"
      assert meta["idempotency_key"] == "job-1"
    end

    test "dimensions are read from PNG and JPEG headers and attached to outputs" do
      png = <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 640::32, 480::32, 8, 2, 0, 0, 0>>
      assert Images.dimensions(png) == {:ok, {640, 480}}

      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xC0, 0, 17, 8, 1024::16, 768::16, 3>>
      assert Images.dimensions(jpeg) == {:ok, {768, 1024}}
      assert Images.dimensions("nope") == :error

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)

        Req.Test.json(conn, %{
          "data" => [%{"b64_json" => Base.encode64(png), "media_type" => "image/png"}]
        })
      end)

      ep = endpoint_fixture()

      assert {:ok, %{images: [%{width: 640, height: 480}]}} =
               PhoenixKitAI.edit_image(ep.uuid, "x", [@jpeg])
    end

    test "an adapter with its own vision callback is used for describe" do
      defmodule FakeVisionAdapter do
        @behaviour PhoenixKitAI.Provider
        def image_edit(_e, _p, _r, _o), do: {:error, :not_supported}
        def image_generate(_e, _p, _o), do: {:error, :not_supported}
        def image_models(_e), do: {:error, :not_supported}
        def image_options(_e), do: []

        def vision(_endpoint, messages, options) do
          send(self(), {:vision_called, messages, options})

          {:ok,
           %{
             "choices" => [%{"message" => %{"content" => "A bar."}}],
             "model" => "fake/vision",
             "latency_ms" => 1
           }}
        end
      end

      Application.put_env(:phoenix_kit_ai, :provider_adapters, %{
        "openrouter" => FakeVisionAdapter
      })

      ep = endpoint_fixture()

      assert {:ok, %{text: "A bar.", model: "fake/vision"}} =
               PhoenixKitAI.describe_image(ep.uuid, @jpeg)

      assert_received {:vision_called, [%{role: "user"}], %{response_format: nil}}
    end
  end

  describe "pins" do
    test "preflight refusals never write a usage row" do
      stub(image_answer())
      ep = endpoint_fixture()

      {:error, _} =
        PhoenixKitAI.process_image(ep.uuid, [%{url: "http://127.0.0.1/x.png"}], [:enhance])

      {:error, _} =
        PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:clean_background, :blur_background])

      {:error, _} =
        PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance], model: "vendor/x", strict: true)

      {:error, _} =
        PhoenixKitAI.process_image(ep.uuid, [String.duplicate("x", 30)], [:enhance],
          max_input_bytes: 10
        )

      assert [] = TestRepo.all(from(r in Request, where: r.request_type == "image_edit"))
    end

    test "image_operations/0 lists the built-ins and a host's additions" do
      assert %{enhance: %{prompt: _}, restyle: %{references: :required}} =
               PhoenixKitAI.image_operations()

      Application.put_env(:phoenix_kit_ai, :image_operations, %{
        clean_background: %{prompt: "Studio sweep, {{color}}."}
      })

      # A host spec for a built-in keeps the built-in's group and defaults.
      assert %{
               clean_background: %{
                 prompt: "Studio sweep, {{color}}.",
                 group: :background,
                 defaults: %{color: "white"}
               }
             } =
               PhoenixKitAI.image_operations()
    end

    test "verify: true attaches a verdict, and an error instead when the check cannot run" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", _} ->
            Req.Test.json(conn, %{"data" => @listing})

          {"POST", "/api/v1/images"} ->
            Req.Test.json(conn, image_answer())

          {"POST", "/api/v1/chat/completions"} ->
            send(test_pid, :compared)

            Req.Test.json(
              conn,
              chat_answer(
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

      ep = endpoint_fixture()
      user_uuid = Fixtures.confirmed_user_fixture().uuid

      assert {:ok, %{verification: %{passed: true, summary: "Clean."}}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance],
                 verify: true,
                 user_uuid: user_uuid
               )

      assert_received :compared

      # The check's vision row is billed to the same user as the edit.
      assert [%{user_uuid: ^user_uuid}] =
               TestRepo.all(from(r in Request, where: r.request_type == "image_edit"))

      assert [%{user_uuid: ^user_uuid}] =
               TestRepo.all(from(r in Request, where: r.request_type == "vision"))

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", _} ->
            Req.Test.json(conn, %{"data" => @listing})

          {"POST", "/api/v1/images"} ->
            Req.Test.json(conn, image_answer())

          {"POST", "/api/v1/chat/completions"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, "{}")
        end
      end)

      assert {:ok, %{images: [_], verification: %{error: {:api_error, 500}}}} =
               PhoenixKitAI.process_image(ep.uuid, [@jpeg], [:enhance], verify: true)
    end
  end
end
