defmodule PhoenixKitAI.CapabilitiesFilesImagesTest do
  @moduledoc """
  The two capabilities beside `vision`: `file_input` (documents, PDF in)
  and `image_output` (the model generates images) — what each catalogue
  says, what an admin may declare, and the snapshot that keeps them over a
  restart. HTTP goes to `Req.Test` stubs only.
  """

  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKitAI.Capabilities
  alias PhoenixKitAI.ModelCapability
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @openrouter "https://openrouter.ai/api/v1"

  describe "OpenRouter rows" do
    test "file among the input modalities is file_input; image among the outputs is image_output" do
      assert %Capabilities{vision: :yes, file_input: :yes, image_output: :no} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{
                   "input_modalities" => ["text", "image", "file"],
                   "output_modalities" => ["text"]
                 }
               })

      assert %Capabilities{vision: :yes, file_input: :no, image_output: :yes} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{
                   "input_modalities" => ["text", "image"],
                   "output_modalities" => ["image", "text"]
                 }
               })
    end

    test "without the modality lists the modality string decides, each side for its own" do
      assert %Capabilities{file_input: :yes, image_output: :yes} =
               Capabilities.from_openrouter(%{
                 "architecture" => %{"modality" => "text+image+file->text+image"}
               })

      assert %Capabilities{file_input: :no, image_output: :no} =
               Capabilities.from_openrouter(%{"architecture" => %{"modality" => "text->text"}})
    end

    test "a row that says nothing is unknown for both, not no" do
      assert %Capabilities{file_input: :unknown, image_output: :unknown} =
               Capabilities.from_openrouter(%{"id" => "x"})
    end
  end

  describe "Anthropic rows" do
    test "pdf_input is file_input; no Claude generates images" do
      assert %Capabilities{file_input: :yes, image_output: :no} =
               Capabilities.from_anthropic(%{
                 "id" => "claude-opus-5-5",
                 "capabilities" => %{"pdf_input" => %{"supported" => true}}
               })

      assert %Capabilities{file_input: :no} =
               Capabilities.from_anthropic(%{
                 "id" => "claude-3-haiku",
                 "capabilities" => %{"pdf_input" => %{"supported" => false}}
               })
    end

    test "null capabilities leave file_input unknown" do
      assert %Capabilities{file_input: :unknown, image_output: :no} =
               Capabilities.from_anthropic(%{"id" => "claude-mystery", "capabilities" => nil})
    end
  end

  describe "declaring" do
    test "both can be declared on the endpoint, for its model only" do
      assert :file_input in Capabilities.declarable()
      assert :image_output in Capabilities.declarable()

      endpoint = %{
        model: "m",
        provider_settings: %{
          "capabilities" => %{"model" => "m", "file_input" => "yes", "image_output" => "no"}
        }
      }

      assert Capabilities.declared(endpoint) == %{file_input: :yes, image_output: :no}
    end

    test "a declaration fills only what the catalogue does not know; a contradicted one is a conflict" do
      catalogue = %Capabilities{file_input: :unknown, image_output: :no}
      declared = %{file_input: :yes, image_output: :yes}

      assert %Capabilities{file_input: :yes, image_output: :no, source: :declared} =
               Capabilities.merge(catalogue, declared)

      assert Capabilities.conflicts(catalogue, declared) == [:image_output]
    end
  end

  describe "in words" do
    test "the requirement labels name documents and image generation" do
      assert PhoenixKitAI.Tasks.need_label(:file_input) == "documents"
      assert PhoenixKitAI.Tasks.need_label(:image_output) == "image generation"

      assert PhoenixKitAI.Tasks.need_labels([:vision, :file_input]) == "images, documents"
    end
  end

  describe "the snapshot" do
    setup do
      stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
      {:ok, stub: stub}
    end

    defp start_cache(stub) do
      pid =
        start_supervised!(
          {Capabilities, initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []}
        )

      Req.Test.allow(stub, self(), pid)
      _ = :sys.get_state(pid)
      pid
    end

    test "a refresh writes both flags for the endpoints' models", %{stub: stub} do
      {:ok, _} =
        PhoenixKitAI.create_endpoint(%{
          name: "Files #{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "google/gemini-image",
          api_key: "sk-or-v1-test-key"
        })

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "google/gemini-image",
              "architecture" => %{
                "input_modalities" => ["text", "image", "file"],
                "output_modalities" => ["image", "text"]
              }
            }
          ]
        })
      end)

      start_cache(stub)
      assert :ok = Capabilities.refresh()

      assert [%ModelCapability{file_input: "yes", image_output: "yes"}] =
               TestRepo.all(ModelCapability)
    end

    test "a restart reads both flags back", %{stub: stub} do
      TestRepo.insert!(%ModelCapability{
        base_url: @openrouter,
        model: "v/m",
        vision: "unknown",
        tools: "unknown",
        json_schema: "unknown",
        json: "unknown",
        file_input: "yes",
        image_output: "no",
        fetched_at: ~U[2026-10-01 00:00:00Z]
      })

      start_cache(stub)

      assert %Capabilities{file_input: :yes, image_output: :no} =
               Capabilities.lookup(@openrouter, "v/m")
    end
  end
end
