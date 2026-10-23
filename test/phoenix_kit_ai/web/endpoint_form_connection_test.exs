defmodule PhoenixKitAI.Web.EndpointFormConnectionTest do
  @moduledoc """
  Picking the connection on the endpoint form, and what the form offers for
  a model the provider's catalogue says nothing about.

  * A provider with exactly one usable connection (one with credentials)
    has it picked at once — on a new endpoint's mount and when the provider
    changes — so the model section opens without a click. An explicit
    choice, a prefilled one and an edited endpoint's stored one are never
    replaced.
  * Each connection card is a toggle button whose `aria-pressed` and radio
    mark say whether it is picked; its status badge ("Connected") is a
    separate thing.
  * A model whose `/models` row lists no parameters gets the standard
    OpenAI-compatible ones, and an unknown context reads "unknown", not
    "0 tokens".

  Usable connections are seeded with `"status" => "connected"` and no
  `api_key`: core counts them as connected, while the form's fetch finds no
  key to send and stops there, so no validation goes over the network.
  """

  use PhoenixKitAI.LiveCase

  @picker "#endpoint-provider-picker"

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp usable(seed, prefix), do: seed.(unique(prefix), data: %{"status" => "connected"})

  defp card(uuid), do: "#{@picker} button[data-connection='#{uuid}']"

  defp pressed?(view, uuid) do
    view
    |> element(card(uuid))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("aria-pressed")
    |> Kernel.==(["true"])
  end

  defp active_connection(view), do: :sys.get_state(view.pid).socket.assigns.active_connection

  defp change_provider(view, provider) do
    view
    |> element("#ai-endpoint-form")
    |> render_change(%{"endpoint" => %{"provider" => provider}})
  end

  describe "a new endpoint" do
    test "a provider with one usable connection has it picked and the model section open",
         %{conn: conn} do
      %{uuid: uuid} = usable(&seed_openrouter_connection/2, "solo")

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/new")

      assert active_connection(view) == uuid
      assert pressed?(view, uuid)
      refute html =~ "Pick an integration above to load available models"
      assert has_element?(view, "#endpoint-model-type")
    end

    test "with two usable connections nothing is picked and both cards say so",
         %{conn: conn} do
      %{uuid: a} = usable(&seed_openrouter_connection/2, "first")
      %{uuid: b} = usable(&seed_openrouter_connection/2, "second")

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/new")

      assert active_connection(view) == nil
      refute pressed?(view, a)
      refute pressed?(view, b)
      assert html =~ "Pick an integration above to load available models"

      view |> element(card(a)) |> render_click()

      assert active_connection(view) == a
      assert pressed?(view, a)
      refute pressed?(view, b)
    end

    test "a connection without credentials is not picked, even as the only one",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter_connection(unique("nokey"))

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assert active_connection(view) == nil
      refute pressed?(view, uuid)
    end

    test "the only usable one is picked when the other connection has no credentials",
         %{conn: conn} do
      seed_openrouter_connection(unique("nokey"))
      %{uuid: uuid} = usable(&seed_openrouter_connection/2, "keyed")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assert active_connection(view) == uuid
    end

    test "a connection the recommendation link names wins over the sole usable one",
         %{conn: conn} do
      %{uuid: named} = seed_openrouter_connection(unique("named"))
      usable(&seed_openrouter_connection/2, "other")

      {:ok, view, _html} =
        live(conn, "/en/admin/ai/endpoints/new?integration_uuid=#{named}&model=x/y")

      assert active_connection(view) == named
    end

    test "the provider shown is one with a connection, and its connection is picked",
         %{conn: conn} do
      # OpenRouter is the schema's default provider, but it has no
      # connection here, so the dropdown offers only Mistral.
      %{uuid: uuid} = usable(&seed_mistral_connection/2, "only-mistral")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assert :sys.get_state(view.pid).socket.assigns.current_provider == "mistral"
      assert active_connection(view) == uuid
      assert pressed?(view, uuid)
    end

    test "changing the provider picks the new provider's only usable connection",
         %{conn: conn} do
      seed_openrouter_connection(unique("or-a"))
      seed_openrouter_connection(unique("or-b"))
      %{uuid: mistral} = usable(&seed_mistral_connection/2, "mistral")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      assert active_connection(view) == nil

      html = change_provider(view, "mistral")

      assert active_connection(view) == mistral
      assert pressed?(view, mistral)
      refute html =~ "Pick an integration above to load available models"
    end

    test "a connection the person unpicked stays unpicked while the provider stays",
         %{conn: conn} do
      %{uuid: uuid} = usable(&seed_openrouter_connection/2, "solo")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      view |> element(card(uuid)) |> render_click()
      assert active_connection(view) == nil

      view
      |> element("#ai-endpoint-form")
      |> render_change(%{"endpoint" => %{"provider" => "openrouter", "name" => "Typed"}})

      assert active_connection(view) == nil
      refute pressed?(view, uuid)
    end
  end

  describe "the connection cards" do
    test "a connected card that is not picked shows its status apart from the selection",
         %{conn: conn} do
      %{uuid: a} = usable(&seed_openrouter_connection/2, "first")
      usable(&seed_openrouter_connection/2, "second")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assert has_element?(view, card(a) <> "[aria-pressed='false']", "Connected")
      assert has_element?(view, card(a) <> " [data-selection-mark]:not([data-selected])")

      view |> element(card(a)) |> render_click()

      assert has_element?(view, card(a) <> "[aria-pressed='true']", "Connected")
      assert has_element?(view, card(a) <> " [data-selection-mark][data-selected]")
    end
  end

  describe "an edited endpoint" do
    test "keeps its stored connection, not the provider's only usable one", %{conn: conn} do
      %{uuid: stored} = seed_openrouter_connection(unique("stored"))
      usable(&seed_openrouter_connection/2, "usable")
      endpoint = fixture_endpoint(integration_uuid: stored)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert active_connection(view) == stored
      assert pressed?(view, stored)
    end

    test "with no stored connection, picks none on mount", %{conn: conn} do
      %{uuid: uuid} = usable(&seed_openrouter_connection/2, "usable")
      endpoint = fixture_endpoint(integration_uuid: nil)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert active_connection(view) == nil
      refute pressed?(view, uuid)
    end

    test "back on its own provider, does not pick a connection other than the stored one",
         %{conn: conn} do
      %{uuid: stored} = seed_openrouter_connection(unique("stored"))
      usable(&seed_openrouter_connection/2, "usable")
      seed_mistral_connection(unique("mistral"))
      endpoint = fixture_endpoint(integration_uuid: stored)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      change_provider(view, "mistral")
      change_provider(view, "openrouter")

      assert active_connection(view) == nil
    end
  end

  describe "a model the catalogue says nothing about" do
    # Plain ids, as an OpenAI-compatible `/models` without a catalogue
    # returns them.
    @plain_models %{
      "data" => [
        %{"id" => "glm-4.6", "object" => "model"},
        %{"id" => "glm-4.5-air", "object" => "model"}
      ]
    }

    defp stub_models(body) do
      stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
      Req.Test.stub(stub, fn conn -> Plug.Conn.send_resp(conn, 200, Jason.encode!(body)) end)
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
      stub
    end

    # The new-endpoint form with a connection picked (while it had no key,
    # so the form validated nothing over the network) and the plain list
    # loaded.
    defp form_with_plain_models(conn) do
      stub = stub_models(@plain_models)
      name = unique("plain")
      %{uuid: uuid} = seed_openrouter_connection(name)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      Req.Test.allow(stub, self(), view.pid)
      render_hook(view, "select_provider_connection", %{"uuid" => uuid})

      seed_openrouter_connection(name, data: %{"api_key" => "sk-plain-key"})
      send(view.pid, {:validation_done, uuid, :ok})
      render_async(view, 2_000)

      view
    end

    test "a model from the plain list can be picked", %{conn: conn} do
      view = form_with_plain_models(conn)

      view |> element("button[phx-value-model='glm-4.6']") |> render_click()

      assert has_element?(view, "input[name='endpoint[model]'][value='glm-4.6']")
      assert has_element?(view, "[data-model-card='glm-4.6']")
    end

    test "shows temperature, max tokens, top p and stop, and an unknown context",
         %{conn: conn} do
      view = form_with_plain_models(conn)

      html = view |> element("button[phx-value-model='glm-4.6']") |> render_click()

      for field <- ~w(temperature max_tokens top_p) do
        assert has_element?(view, "input[name='endpoint[#{field}]']")
      end

      assert has_element?(view, "textarea[name='endpoint[stop]']")

      for field <- ~w(top_k frequency_penalty presence_penalty repetition_penalty seed) do
        refute has_element?(view, "[name='endpoint[#{field}]']")
      end

      assert html =~ "Context: unknown"
      refute html =~ "Context: 0 tokens"
    end

    test "a model id typed by hand is taken when the list could not be loaded",
         %{conn: conn} do
      stub =
        Module.concat(__MODULE__, "FailStub#{System.unique_integer([:positive])}")

      Req.Test.stub(stub, fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end)
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      name = unique("manual")
      %{uuid: uuid} = seed_openrouter_connection(name)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      Req.Test.allow(stub, self(), view.pid)
      render_hook(view, "select_provider_connection", %{"uuid" => uuid})
      seed_openrouter_connection(name, data: %{"api_key" => "sk-manual-key"})
      # The key arriving is announced, which unlocks the manual entry.
      send(view.pid, {:integration_connected, "openrouter", uuid})
      send(view.pid, {:validation_done, uuid, :ok})
      render_async(view, 2_000)

      assert has_element?(view, "#manual_model_input:not([disabled])")

      render_click(view, "set_manual_model", %{"model" => "glm-4.5-air"})

      assert has_element?(view, "input[name='endpoint[model]'][value='glm-4.5-air']")
      assert has_element?(view, "input[name='endpoint[temperature]']")
    end
  end
end
