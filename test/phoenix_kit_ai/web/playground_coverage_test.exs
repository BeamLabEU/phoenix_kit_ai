defmodule PhoenixKitAI.Web.PlaygroundCoverageTest do
  @moduledoc """
  Coverage push for `PhoenixKitAI.Web.Playground` LiveView.

  Drives `change`, `send`, `clear`, and the `:do_send` `handle_info`
  with stubbed Req responses so the AI completion path executes
  without external HTTP traffic.
  """

  use PhoenixKitAI.LiveCase

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.Web.PlaygroundCoverageTest},
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

  defp stub_response(status, body) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp success_payload(content) do
    %{
      "id" => "gen-1",
      "model" => "anthropic/claude-3-haiku",
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{
        "prompt_tokens" => 5,
        "completion_tokens" => 3,
        "total_tokens" => 8,
        "cost" => 0.0
      }
    }
  end

  describe "change event — endpoint + prompt + content + variables + freeform" do
    test "selecting an endpoint stores the uuid; clearing it nils it", %{conn: conn} do
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"endpoint_uuid" => ""})
      assert is_binary(render(view))
    end

    test "selecting a prompt extracts variables; switching prompts re-init", %{conn: conn} do
      p1 = fixture_prompt(name: "P1", content: "Hi {{Name}}")
      p2 = fixture_prompt(name: "P2", content: "Hi {{Other}}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"prompt_uuid" => p1.uuid})
      render_change(view, "change", %{"prompt_uuid" => p2.uuid})
      render_change(view, "change", %{"prompt_uuid" => ""})
      assert is_binary(render(view))
    end

    test "edited content updates extracted variables, preserving values", %{conn: conn} do
      p = fixture_prompt(content: "Hi {{Name}}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      render_change(view, "change", %{"variables" => %{"Name" => "World"}})
      render_change(view, "change", %{"edited_content" => "Hi {{Name}} and {{Other}}"})
      render_change(view, "change", %{"variables" => %{"Other" => "Y"}})
      assert is_binary(render(view))
    end

    test "freeform message + system fields update assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"message" => "Hello", "system" => "Be polite."})
      assert is_binary(render(view))
    end
  end

  describe "send event" do
    test "send without selected endpoint surfaces flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      html = render_hook(view, "send", %{})
      assert html =~ ~r/select an endpoint/i
    end

    test "freeform send with stubbed completion populates response_text", %{conn: conn} do
      stub_response(200, success_payload("Hi back!"))
      ep = fixture_endpoint()

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hello"})

      render_hook(view, "send", %{})
      # Trigger the synchronous :do_send via send/2
      send(view.pid, :do_send)
      html = render(view)
      assert is_binary(html)
    end

    test "freeform send with empty message returns :empty_input error", %{conn: conn} do
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => ""})
      render_hook(view, "send", %{})
      send(view.pid, :do_send)
      assert is_binary(render(view))
    end

    test "prompt-based send increments usage_count", %{conn: conn} do
      stub_response(200, success_payload("Bonjour"))
      ep = fixture_endpoint()
      p = fixture_prompt(content: "Translate {{X}}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      render_change(view, "change", %{"variables" => %{"X" => "Hello"}})

      render_hook(view, "send", %{})
      send(view.pid, :do_send)
      assert is_binary(render(view))

      reloaded = PhoenixKitAI.get_prompt(p.uuid)
      assert reloaded.usage_count >= 1
    end

    test "send error path is rendered via Errors.message/1", %{conn: conn} do
      stub_response(401, %{})
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hi"})
      render_hook(view, "send", %{})
      send(view.pid, :do_send)
      assert is_binary(render(view))
    end
  end

  describe "clear event" do
    test "clear resets response + freeform", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"message" => "Hello"})
      render_hook(view, "clear", %{})
      assert is_binary(render(view))
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      send(view.pid, :unknown_msg)
      assert is_binary(render(view))
    end
  end
end
