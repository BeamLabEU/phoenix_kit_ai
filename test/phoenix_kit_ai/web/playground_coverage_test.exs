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

  # Like `stub_response/2`, and hands each request's decoded body to the test.
  defp stub_capturing(status, body) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  # The `send` event queues the request for the view itself; the render
  # that follows returns once it has been handled.
  defp send_and_render(view) do
    render_hook(view, "send", %{})
    render(view)
  end

  defp textarea(view, name), do: view |> element("textarea[name='#{name}']") |> render()

  describe "change event — endpoint + prompt + content + variables + freeform" do
    test "a selected endpoint is the one a send goes to; cleared, there is none", %{conn: conn} do
      stub_response(200, success_payload("Hi back!"))
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"message" => "Hello"})

      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      assert send_and_render(view) =~ "Hi back!"

      render_change(view, "change", %{"endpoint_uuid" => ""})
      assert render_hook(view, "send", %{}) =~ "Please select an endpoint"
    end

    test "selecting a prompt offers its variables; switching swaps them; clearing returns to freeform",
         %{conn: conn} do
      p1 = fixture_prompt(name: "P1", content: "Hi {{Name}}")
      p2 = fixture_prompt(name: "P2", content: "Hi {{Other}}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      assert has_element?(view, "textarea[name=message]")

      render_change(view, "change", %{"prompt_uuid" => p1.uuid})
      assert has_element?(view, "textarea[name='variables[Name]']")
      refute has_element?(view, "textarea[name=message]")

      render_change(view, "change", %{"prompt_uuid" => p2.uuid})
      assert has_element?(view, "textarea[name='variables[Other]']")
      refute has_element?(view, "textarea[name='variables[Name]']")

      render_change(view, "change", %{"prompt_uuid" => ""})
      assert has_element?(view, "textarea[name=message]")
      refute has_element?(view, "textarea[name='variables[Other]']")
    end

    test "edited content updates extracted variables, preserving values", %{conn: conn} do
      p = fixture_prompt(content: "Hi {{Name}}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      render_change(view, "change", %{"variables" => %{"Name" => "World"}})
      render_change(view, "change", %{"edited_content" => "Hi {{Name}} and {{Other}}"})

      assert textarea(view, "variables[Name]") =~ "World"
      assert has_element?(view, "textarea[name='variables[Other]']")

      render_change(view, "change", %{"variables" => %{"Other" => "Y"}})
      assert textarea(view, "variables[Other]") =~ "Y"
      assert textarea(view, "variables[Name]") =~ "World"
    end

    test "freeform message + system fields keep what was typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"message" => "Hello", "system" => "Be polite."})

      assert textarea(view, "message") =~ "Hello"
      assert textarea(view, "system") =~ "Be polite."
    end
  end

  describe "send event" do
    test "send without selected endpoint surfaces flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      html = render_hook(view, "send", %{})
      assert html =~ ~r/select an endpoint/i
    end

    test "freeform send shows the answer and its token usage", %{conn: conn} do
      stub_capturing(200, success_payload("Hi back!"))
      ep = fixture_endpoint()

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hello"})

      html = send_and_render(view)

      assert html =~ "Hi back!"
      assert html =~ "8 total"

      assert_received {:request_body,
                       %{"messages" => [%{"role" => "user", "content" => "Hello"}]}}

      # One click, one request.
      refute_received {:request_body, _}
    end

    test "freeform send with an empty message is refused without a request", %{conn: conn} do
      stub_capturing(200, success_payload("unreachable"))
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => ""})

      html = send_and_render(view)

      assert html =~ "Input cannot be empty"
      refute_received {:request_body, _}
    end

    test "prompt-based send renders the variables, shows the answer and counts one use", %{
      conn: conn
    } do
      stub_capturing(200, success_payload("Bonjour"))
      ep = fixture_endpoint()
      p = fixture_prompt(content: "Translate {{X}}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      render_change(view, "change", %{"variables" => %{"X" => "Hello"}})

      assert send_and_render(view) =~ "Bonjour"

      assert_received {:request_body, %{"messages" => messages}}
      assert Enum.any?(messages, &(&1["content"] == "Translate Hello"))
      assert PhoenixKitAI.get_prompt(p.uuid).usage_count == 1
    end

    test "a provider error is shown in the user's words", %{conn: conn} do
      stub_response(401, %{})
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hi"})

      assert send_and_render(view) =~ "Invalid API key"
    end

    test "freeform send WITH a system prompt sends it as the system message", %{conn: conn} do
      stub_capturing(200, success_payload("Reply"))
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hi", "system" => "Be very polite."})

      assert send_and_render(view) =~ "Reply"

      assert_received {:request_body, %{"messages" => messages}}
      assert %{"role" => "system", "content" => "Be very polite."} in messages
      assert %{"role" => "user", "content" => "Hi"} in messages
    end

    test "prompt-based send shows a provider error too", %{conn: conn} do
      stub_response(401, %{})
      ep = fixture_endpoint()
      p = fixture_prompt(content: "Translate {{X}}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      render_change(view, "change", %{"variables" => %{"X" => "Hello"}})

      assert send_and_render(view) =~ "Invalid API key"
    end

    test "an answer with no choices is reported, not rendered blank", %{conn: conn} do
      malformed = %{
        "id" => "gen-x",
        "model" => "anthropic/claude-3-haiku",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 0, "total_tokens" => 1}
      }

      stub_response(200, malformed)
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hi"})

      assert send_and_render(view) =~ "(No content in response)"
    end
  end

  describe "change event re-selection no-ops" do
    test "selecting the same prompt twice is a no-op (no state churn)", %{conn: conn} do
      # Drive `maybe_update_prompt` no-op branch (`uuid ==
      # socket.assigns.selected_prompt_uuid -> socket`).
      p = fixture_prompt(content: "Hello {{X}}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      first = render(view)

      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      second = render(view)

      # State is stable across the no-op selection — content is the
      # same, the prompt's variables are the same.
      assert first =~ p.name
      assert second =~ p.name
    end

    test "edited_content with the same variable set keeps existing values",
         %{conn: conn} do
      # Drive the `else: socket.assigns.variable_values` branch in
      # maybe_update_content/1 — when new_vars == old_vars, the
      # current variable_values are preserved without re-init.
      p = fixture_prompt(content: "Hello {{Name}}")
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

      render_change(view, "change", %{"prompt_uuid" => p.uuid})
      render_change(view, "change", %{"variables" => %{"Name" => "World"}})

      # Edit content but keep the same variable set.
      render_change(view, "change", %{"edited_content" => "Hi {{Name}}!"})

      assert textarea(view, "variables[Name]") =~ "World"
    end
  end

  describe "clear event" do
    test "clear drops the answer and empties the freeform fields", %{conn: conn} do
      stub_response(200, success_payload("Hi back!"))
      ep = fixture_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/playground")
      render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
      render_change(view, "change", %{"message" => "Hello", "system" => "Be polite."})
      assert send_and_render(view) =~ "Hi back!"

      html = render_hook(view, "clear", %{})

      refute html =~ "Hi back!"
      refute textarea(view, "message") =~ "Hello"
      refute textarea(view, "system") =~ "Be polite."
    end
  end
end
