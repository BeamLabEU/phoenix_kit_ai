defmodule PhoenixKitAI.Components.AITranslateEmbedAuthorizeTest do
  @moduledoc """
  `use AITranslate.Embed, authorize: …` — the modal's six events pass only
  while `authorize` answers truthy for the live socket; a refusal halts the
  event with an error flash and enqueues nothing. Omitted, every event is
  dispatched as before.
  """

  use PhoenixKitAI.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.Components.AITranslate.Embed
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defmodule Gate do
    @moduledoc false
    # Reads the socket as it is at the event, the way a host checks a right.
    def allowed?(socket, _extra), do: socket.assigns[:allowed?] == true
  end

  defmodule Binding do
    @moduledoc false
    def actor_uuid(_socket), do: nil
    def existing_translation_langs(_type, _assigns), do: []
    def apply_translation(socket, _lang, _fields), do: socket
  end

  defmodule FormBase do
    @moduledoc false
    use Phoenix.Component
    alias PhoenixKitAI.Components.AITranslate.FormGlue

    def mount(session, socket) do
      socket
      |> FormGlue.assign_ai_translation(
        "embed_authorize_probe",
        %{uuid: session["resource_uuid"]},
        Binding
      )
      |> Phoenix.Component.assign(
        allowed?: session["allowed?"],
        ai_selected_endpoint: session["endpoint_uuid"],
        ai_selected_prompt: session["prompt_uuid"]
      )
    end

    def render(assigns) do
      ~H"""
      <div>
        <p id="modal">{inspect(@ai_modal_open)}</p>
        <p id="endpoint">{@ai_selected_endpoint}</p>
        <p id="error">{Phoenix.Flash.get(@flash, :error)}</p>
        <p id="info">{Phoenix.Flash.get(@flash, :info)}</p>
      </div>
      """
    end
  end

  defmodule GatedForm do
    @moduledoc false
    use Phoenix.LiveView

    use PhoenixKitAI.Components.AITranslate.Embed,
      authorize: {PhoenixKitAI.Components.AITranslateEmbedAuthorizeTest.Gate, :allowed?, [:x]}

    alias PhoenixKitAI.Components.AITranslateEmbedAuthorizeTest.FormBase

    @impl true
    def mount(_params, session, socket), do: {:ok, FormBase.mount(session, socket)}

    @impl true
    def render(assigns), do: FormBase.render(assigns)
  end

  defmodule UngatedForm do
    @moduledoc false
    use Phoenix.LiveView
    use PhoenixKitAI.Components.AITranslate.Embed

    alias PhoenixKitAI.Components.AITranslateEmbedAuthorizeTest.FormBase

    @impl true
    def mount(_params, session, socket), do: {:ok, FormBase.mount(session, socket)}

    @impl true
    def render(assigns), do: FormBase.render(assigns)
  end

  setup do
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

    {:ok,
     session: %{
       "resource_uuid" => Ecto.UUID.generate(),
       "endpoint_uuid" => Ecto.UUID.generate(),
       "prompt_uuid" => Ecto.UUID.generate()
     }}
  end

  defp jobs(resource_uuid) do
    TestRepo.aggregate(
      from(j in "oban_jobs", where: fragment("?->>'resource_uuid' = ?", j.args, ^resource_uuid)),
      :count
    )
  end

  defp events do
    [
      {"ai_toggle_modal", %{}},
      {"ai_select_endpoint", %{"endpoint_uuid" => Ecto.UUID.generate()}},
      {"ai_select_prompt", %{"prompt_uuid" => Ecto.UUID.generate()}},
      {"ai_select_scope", %{"scope" => "all"}},
      {"ai_generate_prompt", %{}},
      {"ai_translate_lang", %{"lang" => "de"}}
    ]
  end

  test "a refusing authorize halts every modal event and enqueues nothing",
       %{conn: conn, session: session} do
    {:ok, view, _html} =
      live_isolated(conn, GatedForm, session: Map.put(session, "allowed?", false))

    for {event, params} <- events() do
      html = render_click(view, event, params)
      assert html =~ "permission to translate", "#{event} was not refused"
    end

    assert has_element?(view, "#modal", "false")
    assert has_element?(view, "#endpoint", session["endpoint_uuid"])
    assert jobs(session["resource_uuid"]) == 0
  end

  test "an allowing authorize dispatches", %{conn: conn, session: session} do
    {:ok, view, _html} =
      live_isolated(conn, GatedForm, session: Map.put(session, "allowed?", true))

    render_click(view, "ai_toggle_modal", %{})
    assert has_element?(view, "#modal", "true")

    html = render_click(view, "ai_translate_lang", %{"lang" => "de"})
    refute html =~ "permission to translate"
    assert jobs(session["resource_uuid"]) == 1
  end

  test "omitted, every event is dispatched as before", %{conn: conn, session: session} do
    {:ok, view, _html} = live_isolated(conn, UngatedForm, session: session)

    render_click(view, "ai_toggle_modal", %{})
    assert has_element?(view, "#modal", "true")

    render_click(view, "ai_translate_lang", %{"lang" => "de"})
    assert jobs(session["resource_uuid"]) == 1
  end

  test "an authorize that is not a function or MFA is refused at mount" do
    assert_raise ArgumentError, ~r/:authorize must be/, fn ->
      Embed.on_mount(
        [authorize: :nope],
        %{},
        %{},
        %Phoenix.LiveView.Socket{}
      )
    end
  end
end
