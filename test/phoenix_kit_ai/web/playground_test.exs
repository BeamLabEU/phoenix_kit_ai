defmodule PhoenixKitAI.Web.PlaygroundTest do
  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Images.ImageModels

  describe "mount" do
    test "renders the playground heading + configuration card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")
      assert html =~ "AI Playground"
      assert html =~ "Configuration"
    end

    test "pre-populates the endpoint dropdown from the DB", %{conn: conn} do
      endpoint = fixture_endpoint(name: "Playground Endpoint")

      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")
      # The endpoint name appears in the <option> within the
      # configuration <select>; assert against the actual rendered
      # name rather than a fallback that hides UI regressions.
      assert html =~ "Playground Endpoint"
      assert html =~ endpoint.uuid
    end
  end

  describe "send with no endpoint selected" do
    test "flashes a translated error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      html = render_click(view, "send", %{})
      assert html =~ "Please select an endpoint"
    end
  end

  describe "send button" do
    test "declares phx-disable-with so a slow send can't be double-submitted",
         %{conn: conn} do
      _endpoint = fixture_endpoint(name: "Playground Endpoint")
      {:ok, _view, html} = live(conn, "/en/admin/ai/playground")

      # The submit button lives inside `<form phx-submit="send">` and
      # gets `phx-disable-with` from the C5 fix in the 2026-04-26
      # re-validation pass.
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages and logs at :debug", %{conn: conn} do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, :unknown_msg_from_another_module)
          send(view.pid, {:something_we_dont_care_about, %{}, %{}})

          html = render(view)
          assert html =~ "AI Playground"
        end)

      assert log =~ "[PhoenixKitAI.Web.Playground] unhandled handle_info"
    end
  end

  describe "image edit" do
    test "appears once an endpoint is selected and refuses to send without an image", %{
      conn: conn
    } do
      endpoint = fixture_endpoint(name: "Image Endpoint", model: "google/gemini-2.5-flash-image")
      {:ok, view, html} = live(conn, "/en/admin/ai/playground")
      refute html =~ "playground-image-edit"

      html = render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})
      assert html =~ "Image edit"
      assert has_element?(view, "#playground-image-edit-form")

      html = render_submit(view, "edit_send", %{"edit_prompt" => "make it green"})
      assert html =~ "Please add at least one image"
    end
  end

  describe "image edit card" do
    @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

    setup do
      Application.put_env(:phoenix_kit_ai, :req_options,
        plug: {Req.Test, PhoenixKitAI.Web.PlaygroundTest},
        retry: false
      )

      ImageModels.clear()

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :req_options)
        ImageModels.clear()
      end)

      :ok
    end

    defp stub_images(test_pid) do
      Req.Test.stub(PhoenixKitAI.Web.PlaygroundTest, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/images/models"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => "google/gemini-2.5-flash-image",
                  "name" => "Nano Banana",
                  "supported_parameters" => %{
                    "aspect_ratio" => %{"type" => "enum", "values" => ["1:1", "4:3"]}
                  }
                },
                %{
                  "id" => "openai/gpt-image-1",
                  "name" => "GPT Image 1",
                  "supported_parameters" => %{
                    "quality" => %{"type" => "enum", "values" => ["low", "high"]}
                  }
                }
              ]
            })

          {"POST", "/api/v1/images"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:images_post, Jason.decode!(raw)})

            Req.Test.json(conn, %{
              "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/png"}]
            })

          {"POST", "/api/v1/chat/completions"} ->
            send(test_pid, :chat_post)

            Req.Test.json(conn, %{
              "choices" => [%{"message" => %{"content" => "A bar."}}],
              "model" => "m"
            })
        end
      end)
    end

    test "loads the model list asynchronously and offers the model's options", %{conn: conn} do
      stub_images(self())
      endpoint = fixture_endpoint(name: "Img", model: "google/gemini-2.5-flash-image")
      {:ok, view, _} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})

      render_click(view, "load_image_models", %{})
      html = render_async(view)
      assert html =~ "Nano Banana"
      assert has_element?(view, "select[name=edit_model]")
      assert has_element?(view, "select[name='opt[aspect_ratio]']")
      refute has_element?(view, "select[name='opt[quality]']")

      # The option selects follow the model override.
      render_change(view, "edit_change", %{"edit_model" => "openai/gpt-image-1"})
      assert has_element?(view, "select[name='opt[quality]']")
      refute has_element?(view, "select[name='opt[aspect_ratio]']")

      # A new endpoint starts without a listing, so without selects.
      other = fixture_endpoint(name: "Img 2", model: "google/gemini-2.5-flash-image")
      render_change(view, "change", %{"endpoint_uuid" => other.uuid})
      refute has_element?(view, "select[name='opt[quality]']")
    end

    test "a crashed model-list task leaves an edit that is still running alone", %{conn: conn} do
      test_pid = self()
      crash_key = {__MODULE__, :crash_listing}
      :persistent_term.put(crash_key, false)
      on_exit(fn -> :persistent_term.erase(crash_key) end)

      Req.Test.stub(PhoenixKitAI.Web.PlaygroundTest, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/images/models"} ->
            if :persistent_term.get(crash_key),
              do: exit(:listing_crashed),
              else: Req.Test.json(conn, %{"data" => []})

          {"POST", "/api/v1/images"} ->
            send(test_pid, {:edit_waiting, self()})

            receive do
              :go -> :ok
            after
              5_000 -> :ok
            end

            Req.Test.json(conn, %{
              "data" => [%{"b64_json" => Base.encode64(@png), "media_type" => "image/png"}]
            })
        end
      end)

      endpoint = fixture_endpoint(name: "Img", model: "google/gemini-2.5-flash-image")
      {:ok, view, _} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})

      view
      |> file_input("#playground-image-edit-form", :edit_images, [
        %{name: "bar.png", content: @png, type: "image/png"}
      ])
      |> render_upload("bar.png")

      render_submit(view, "edit_send", %{"edit_prompt" => "", "ops" => ["enhance"]})
      assert_receive {:edit_waiting, edit_request}, 2_000

      # The edit's own lookup cached the listing; drop it so the click fetches, and crashes.
      ImageModels.clear()
      :persistent_term.put(crash_key, true)

      ExUnit.CaptureLog.capture_log(fn ->
        render_click(view, "load_image_models", %{})
        html = render_until(view, "Something went wrong on our side")
        assert html =~ "Usually 10–40 seconds"
      end)

      send(edit_request, :go)
      html = render_async(view)
      assert html =~ "data:image/png;base64,"
      refute html =~ "Usually 10–40 seconds"
    end

    test "edits an uploaded image through process_image, keeps the bytes for a retry, and describes",
         %{conn: conn} do
      stub_images(self())
      endpoint = fixture_endpoint(name: "Img", model: "google/gemini-2.5-flash-image")
      {:ok, view, _} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})

      view
      |> file_input("#playground-image-edit-form", :edit_images, [
        %{name: "bar.png", content: @png, type: "image/png"}
      ])
      |> render_upload("bar.png")

      html =
        render_submit(view, "edit_send", %{
          "edit_prompt" => "",
          "ops" => ["enhance", "remove_reflections"]
        })

      assert html =~ "Editing…" or html =~ "Usually 10–40 seconds"

      html = render_async(view)
      assert html =~ "data:image/png;base64,"
      assert html =~ "Prompt sent"

      assert_received {:images_post,
                       %{"model" => "google/gemini-2.5-flash-image", "input_references" => [_]}}

      # A second run needs no new upload: the bytes were kept.
      assert render(view) =~ "kept from the last run"
      render_submit(view, "edit_send", %{"edit_prompt" => "Make it pop", "ops" => []})
      render_async(view)
      assert_received {:images_post, %{"prompt" => prompt}}
      assert prompt =~ "Make it pop"

      # Describe shares the same inputs.
      render_submit(view, "edit_send", %{"action" => "describe", "edit_prompt" => "What is it?"})
      html = render_async(view)
      assert_received :chat_post
      assert html =~ "A bar."
    end

    # An async task's exit reaches the LiveView as a message, so poll the render.
    defp render_until(view, text, tries \\ 100) do
      html = render(view)

      cond do
        html =~ text ->
          html

        tries == 0 ->
          flunk("never rendered #{inspect(text)}")

        true ->
          Process.sleep(10)
          render_until(view, text, tries - 1)
      end
    end

    test "guards: no endpoint, no image, no operation", %{conn: conn} do
      endpoint = fixture_endpoint(name: "Img", model: "google/gemini-2.5-flash-image")
      {:ok, view, _} = live(conn, "/en/admin/ai/playground")

      # Without an endpoint the card is not rendered; the handler still answers.
      assert render_click(view, "load_image_models", %{})

      render_change(view, "change", %{"endpoint_uuid" => endpoint.uuid})

      assert render_submit(view, "edit_send", %{"edit_prompt" => "x"}) =~
               "Please add at least one image"

      view
      |> file_input("#playground-image-edit-form", :edit_images, [
        %{name: "bar.png", content: @png, type: "image/png"}
      ])
      |> render_upload("bar.png")

      assert render_submit(view, "edit_send", %{"edit_prompt" => "", "ops" => []}) =~
               "Pick an operation or write an instruction"
    end
  end
end
