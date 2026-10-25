defmodule PhoenixKitAI.Web.JournalRetention do
  @moduledoc """
  The "Journal retention" card of AI → Usage: its state, events, previews
  and broadcasts. `PhoenixKitAI.Web.Endpoints` keeps the socket and hands
  over — `assign_defaults/1` in `mount/3`, `load/1` when the tab opens,
  `handle_event/3` for the `retention_*` events, `handle_async/3` for the
  previews, `handle_setting/3` for core's broadcasts of the two settings.
  The markup is `PhoenixKitAI.Web.Components.JournalRetentionCard`.

  Nothing here decides policy: periods, boundaries, warnings, "shorter",
  the preview and the run are `PhoenixKitAI.Retention`'s. Every event that
  acts — saving, its confirmation, counting, the run — checks the right
  again (`PhoenixKitAI.Web.Access.manage_scope/1`) and hands the context
  function the scope that check read, the scope as it is now. The form's
  own events (typing, choosing, opening or closing a confirmation) change
  only the page's assigns and read no rights. The boundaries a
  confirmation acts on come from the page's assigns (the preview's
  result), never from the event's parameters.
  """

  use Gettext, backend: PhoenixKitAI.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  alias PhoenixKitAI.{Errors, Retention}
  alias PhoenixKitAI.Web.Access

  @acting ~w(retention_save retention_save_confirm retention_run_preview retention_run_confirm)
  @form_only ~w(retention_validate retention_save_cancel retention_run_change retention_run_open
                retention_run_cancel)
  @events @acting ++ @form_only

  @doc "The events of the card, for the LiveView's dispatch."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The card's assigns before anything is read (`mount/3` runs twice)."
  @spec assign_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_defaults(socket) do
    settings = Retention.settings_from(nil)

    socket
    |> assign(:retention, settings)
    |> assign(:retention_last_run, Retention.last_run_from(nil))
    |> assign(:retention_job, nil)
    |> assign(:retention_can_manage, false)
    |> assign(:retention_retained_since, nil)
    |> reset_forms(settings)
  end

  @doc "Reads the periods, the last runs, the pending job and the rights."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    settings = Retention.settings()
    last_run = Retention.last_run()

    socket
    |> assign(:retention, settings)
    |> assign(:retention_last_run, last_run)
    |> assign(:retention_job, Retention.pending_job())
    |> assign(:retention_can_manage, Access.may_manage?(socket))
    |> assign(:retention_retained_since, retained_since(settings, last_run))
    |> reset_forms(settings)
  end

  @doc "Reads where the totals \"for all time\" start (the endpoints tab)."
  @spec assign_retained_since(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_retained_since(socket) do
    assign(
      socket,
      :retention_retained_since,
      retained_since(Retention.settings(), Retention.last_run())
    )
  end

  @doc """
  Where the totals "for all time" start: the oldest journal row, once rows
  may have been deleted — the rows' period is finite, or a run ever deleted
  rows (`rows_deleted_before` of `Retention.last_run/0`) — else `nil` (the
  totals are all time).
  """
  @spec retained_since(map(), map()) :: DateTime.t() | nil
  def retained_since(settings, last_run) do
    if settings.requests != :forever or last_run[:rows_deleted_before] != nil,
      do: Retention.oldest_request_at()
  end

  @doc """
  A broadcast of one of the two settings, drawn from the value in the
  message (never read again: core announces a change before its
  transaction commits). Answers `{:periods | :last_run, socket}`.

  Periods other than the ones shown replace the form; when that discards
  something of the person's — a value typed, a preview or a confirmation
  pending — an info flash says so. Periods the page shows already (its
  own save coming back) change nothing.
  """
  @spec handle_setting(Phoenix.LiveView.Socket.t(), String.t(), term()) ::
          {:periods | :last_run, Phoenix.LiveView.Socket.t()}
  def handle_setting(socket, key, value) do
    if key == Retention.setting_key() do
      settings = Retention.settings_from(value)
      {:periods, put_settings_shown(socket, settings)}
    else
      last_run = Retention.last_run_from(value)

      {:last_run,
       socket
       |> assign(:retention_last_run, last_run)
       |> assign(:retention_job, Retention.pending_job())
       |> assign(:retention_retained_since, retained_since(socket.assigns.retention, last_run))}
    end
  end

  defp put_settings_shown(%{assigns: %{retention: settings}} = socket, settings), do: socket

  defp put_settings_shown(socket, settings) do
    socket =
      if pending?(socket.assigns),
        do:
          put_flash(
            socket,
            :info,
            gettext("Someone else changed the retention periods; the card shows them now")
          ),
        else: socket

    socket
    |> assign(:retention, settings)
    |> assign(
      :retention_retained_since,
      retained_since(settings, socket.assigns.retention_last_run)
    )
    |> reset_forms(settings)
  end

  # Something of the person's the new periods would discard.
  defp pending?(assigns) do
    assigns.retention_save != nil or assigns.retention_run != nil or
      assigns.retention_run_form != default_run_form() or
      Enum.any?(Retention.kinds(), fn kind ->
        parse_period(assigns.retention_form[kind]) != {:ok, assigns.retention[kind]}
      end)
  end

  @doc "Whether `key` is one of the card's two settings."
  @spec setting?(term()) :: boolean()
  def setting?(key), do: key in [Retention.setting_key(), Retention.last_run_key()]

  # ===========================================
  # EVENTS
  # ===========================================

  @doc """
  One of `events/0`. An event that acts is refused without `ai.manage`
  now; the form's own events read no rights (see the moduledoc).
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) when event in @form_only,
    do: {:noreply, form_event(event, params, socket)}

  def handle_event(event, params, socket) when event in @acting do
    case Access.manage_scope(socket) do
      {:ok, scope} -> {:noreply, event(event, params, socket, scope)}
      :error -> {:noreply, refuse(socket)}
    end
  end

  # --- acting: `scope` is the one the right was checked on ---

  defp event("retention_save", params, socket, scope) do
    socket = put_form(socket, params)
    %{retention: loaded, retention_form_errors: errors} = socket.assigns

    if errors == %{},
      do: save(socket, scope, changed_periods(socket.assigns.retention_form, loaded), loaded),
      else: socket
  end

  defp event("retention_save_confirm", _params, socket, scope) do
    case socket.assigns.retention_save do
      %{preview: preview, periods: periods, loaded: loaded} when preview != :loading ->
        put_periods(socket, scope, periods, loaded)

      _none_or_counting ->
        socket
    end
  end

  defp event("retention_run_preview", params, socket, scope) do
    socket = socket |> put_run_form(params) |> assign(:retention_run, nil)

    case run_cutoffs(socket.assigns.retention_run_form, socket.assigns.retention) do
      {:error, errors} ->
        assign(socket, :retention_run_errors, errors)

      {:ok, cutoffs} ->
        start_run_preview(socket, scope, cutoffs)
    end
  end

  defp event("retention_run_confirm", _params, socket, scope) do
    case socket.assigns.retention_run do
      %{confirm: true} = run -> run_now(socket, scope, run)
      _ -> socket
    end
  end

  # --- the form's own: the page's assigns only ---

  defp form_event("retention_validate", params, socket), do: put_form(socket, params)

  defp form_event("retention_save_cancel", _params, socket),
    do: assign(socket, :retention_save, nil)

  defp form_event("retention_run_change", params, socket),
    do: socket |> put_run_form(params) |> assign(:retention_run, nil)

  defp form_event("retention_run_open", _params, socket) do
    run = socket.assigns.retention_run

    if runnable?(run),
      do: assign(socket, :retention_run, %{run | confirm: true}),
      else: socket
  end

  defp form_event("retention_run_cancel", _params, socket) do
    case socket.assigns.retention_run do
      %{} = run -> assign(socket, :retention_run, %{run | confirm: false})
      nil -> socket
    end
  end

  defp refuse(socket) do
    socket
    |> assign(:retention_can_manage, false)
    |> assign(:retention_save, nil)
    |> assign(:retention_run, nil)
    |> put_flash(:error, Errors.message(:forbidden))
  end

  # The kinds to save: those the form changed against what it loaded, and
  # those stored without their change time (read as forever until saved:
  # saving writes what the card shows).
  defp changed_periods(form, loaded) do
    for kind <- Retention.kinds(),
        {:ok, period} <- [parse_period(form[kind])],
        period != loaded[kind] or kind in loaded.unconfirmed,
        into: %{},
        do: {kind, period}
  end

  defp save(socket, _scope, periods, _loaded) when periods == %{},
    do: put_flash(socket, :info, gettext("Nothing to save: the periods are as stored"))

  defp save(socket, scope, periods, loaded) do
    now = DateTime.utc_now()
    shorter = Enum.filter(Retention.kinds(), &shorter?(periods, loaded, &1, now))

    if shorter == [] do
      put_periods(socket, scope, periods, loaded)
    else
      cutoffs =
        Map.new(shorter, fn kind ->
          {:ok, cut} = Retention.cutoff(kind, periods[kind], now)
          {kind, cut}
        end)

      ref = make_ref()

      socket
      |> assign(:retention_save, %{
        ref: ref,
        periods: periods,
        loaded: loaded,
        kinds: shorter,
        cutoffs: cutoffs,
        preview: :loading,
        first_run_at: DateTime.add(now, 24 * 3600)
      })
      |> start_async(:retention_save_preview, fn -> {ref, Retention.preview(scope, cutoffs)} end)
    end
  end

  defp shorter?(periods, loaded, kind, now),
    do: Map.has_key?(periods, kind) and Retention.shorter?(kind, periods[kind], loaded[kind], now)

  defp put_periods(socket, scope, periods, loaded) do
    case Retention.put_settings(scope, periods, loaded) do
      {:ok, settings} ->
        socket
        |> assign(:retention, settings)
        |> assign(
          :retention_retained_since,
          retained_since(settings, socket.assigns.retention_last_run)
        )
        |> reset_forms(settings)
        |> put_flash(:info, gettext("Retention periods saved"))

      {:error, :forbidden} ->
        refuse(socket)

      {:error, reason} ->
        socket |> assign(:retention_save, nil) |> put_flash(:error, Errors.message(reason))
    end
  end

  defp start_run_preview(socket, _scope, cutoffs) when map_size(cutoffs) == 0,
    do: put_flash(socket, :error, Errors.message(:nothing_to_run))

  defp start_run_preview(socket, scope, cutoffs) do
    ref = make_ref()

    socket
    |> assign(:retention_run, %{ref: ref, cutoffs: cutoffs, preview: :loading, confirm: false})
    |> start_async(:retention_run_preview, fn -> {ref, Retention.preview(scope, cutoffs)} end)
  end

  @doc """
  Whether the manual run may be confirmed: counted with something to do,
  or not counted in time (the run checks its boundaries again). A preview
  that failed otherwise (`:preview_failed`, a foreign key) may not.
  """
  @spec runnable?(map() | nil) :: boolean()
  def runnable?(%{preview: {:ok, counts}}),
    do: Enum.any?(Retention.kinds(), &(Map.get(counts, &1, 0) > 0))

  def runnable?(%{preview: {:error, :preview_timeout}}), do: true
  def runnable?(_run), do: false

  # The boundaries the run acts on: the preview's (held at the floor), or
  # with no numbers the ones it was asked for — `run_now/2` holds them again.
  defp run_now(socket, scope, run) do
    cutoffs =
      case run.preview do
        {:ok, %{cutoffs: cutoffs}} -> cutoffs
        _ -> run.cutoffs
      end

    case Retention.run_now(scope, cutoffs) do
      {:ok, _job} ->
        socket
        |> assign(:retention_run, nil)
        |> assign(:retention_job, Retention.pending_job())
        |> put_flash(:info, gettext("The journal cleanup is queued"))

      {:error, :forbidden} ->
        refuse(socket)

      {:error, reason} ->
        socket
        |> assign(:retention_run, %{run | confirm: false})
        |> assign(:retention_job, Retention.pending_job())
        |> put_flash(:error, Errors.message(reason))
    end
  end

  # ===========================================
  # ASYNC
  # ===========================================

  @doc """
  The result of a preview. One whose reference is not the pending one's (a
  form changed or counted again since) is dropped; a task that exited is
  `{:error, :preview_failed}`.
  """
  @spec handle_async(atom(), term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(name, result, socket)
      when name in [:retention_save_preview, :retention_run_preview] do
    key = if name == :retention_save_preview, do: :retention_save, else: :retention_run

    {:noreply,
     case {socket.assigns[key], result} do
       {%{ref: ref} = pending, {:ok, {ref, preview}}} ->
         assign(socket, key, %{pending | preview: preview_result(preview)})

       {%{ref: _} = pending, {:exit, _reason}} ->
         assign(socket, key, %{pending | preview: {:error, :preview_failed}})

       _stale ->
         socket
     end}
  end

  defp preview_result({:ok, counts}), do: {:ok, counts}
  defp preview_result({:error, reason}), do: {:error, reason}

  # ===========================================
  # FORMS
  # ===========================================

  defp reset_forms(socket, settings) do
    socket
    |> assign(:retention_form, Map.new(Retention.kinds(), &{&1, form_value(settings[&1])}))
    |> assign(:retention_form_errors, %{})
    |> assign(:retention_warnings, warnings(settings))
    |> assign(:retention_save, nil)
    |> assign(:retention_run_form, default_run_form())
    |> assign(:retention_run_errors, %{})
    |> assign(:retention_run, nil)
  end

  defp form_value(:forever), do: %{"forever" => true, "n" => "", "unit" => "month"}

  defp form_value({n, unit}),
    do: %{"forever" => false, "n" => Integer.to_string(n), "unit" => Atom.to_string(unit)}

  defp default_run_form,
    do: Map.new(Retention.kinds(), &{&1, %{"mode" => "skip", "n" => "", "unit" => "month"}})

  defp put_form(socket, %{"retention" => %{} = params}) do
    form =
      Map.new(Retention.kinds(), fn kind ->
        old = socket.assigns.retention_form[kind]
        given = params[Atom.to_string(kind)]
        given = if is_map(given), do: given, else: %{}

        {kind,
         %{
           "forever" => forever(given, old),
           "n" => text(given["n"], old["n"]),
           "unit" => text(given["unit"], old["unit"])
         }}
      end)

    socket
    |> assign(:retention_form, form)
    |> assign(:retention_form_errors, errors(form, &parse_period/1))
    |> assign(:retention_warnings, warnings_of(form, socket.assigns.retention))
  end

  defp put_form(socket, _params), do: socket

  # A kind the event did not send keeps its box as it was.
  defp forever(%{"forever" => given}, _old), do: given in ["true", true]
  defp forever(_given, old), do: old["forever"]

  defp put_run_form(socket, %{"retention_run" => %{} = params}) do
    form =
      Map.new(Retention.kinds(), fn kind ->
        old = socket.assigns.retention_run_form[kind]
        given = params[Atom.to_string(kind)]
        given = if is_map(given), do: given, else: %{}

        mode = text(given["mode"], old["mode"])
        mode = if mode in ~w(skip saved value), do: mode, else: "skip"

        {kind,
         %{
           "mode" => mode,
           "n" => text(given["n"], old["n"]),
           "unit" => text(given["unit"], old["unit"])
         }}
      end)

    socket
    |> assign(:retention_run_form, form)
    |> assign(:retention_run_errors, %{})
  end

  defp put_run_form(socket, _params), do: socket

  # A field the form did not send (a disabled one) keeps its value.
  defp text(value, _old) when is_binary(value), do: value
  defp text(_value, old), do: old

  defp errors(form, parse) do
    for {kind, value} <- form,
        {:error, message} <- [parse.(value)],
        into: %{},
        do: {kind, message}
  end

  @doc """
  A form row read as a period: `{:ok, :forever}` when "keep forever" is
  ticked, `{:ok, {n, unit}}` for a whole number in the unit's range, else
  `{:error, message}`.
  """
  @spec parse_period(map()) :: {:ok, Retention.period()} | {:error, String.t()}
  def parse_period(%{"forever" => true}), do: {:ok, :forever}
  def parse_period(value), do: parse_n_unit(value)

  defp parse_n_unit(%{"n" => n, "unit" => unit_text}) do
    with {:ok, unit} <- unit(unit_text),
         {:ok, n} <- whole(n) do
      max = Retention.max_n(unit)

      if n >= 1 and n <= max,
        do: {:ok, {n, unit}},
        else: {:error, gettext("A whole number from 1 to %{max}", max: max)}
    end
  end

  defp unit(text) do
    case Enum.find(Retention.units(), &(Atom.to_string(&1) == text)) do
      nil -> {:error, gettext("Choose days, months or years")}
      unit -> {:ok, unit}
    end
  end

  defp whole(text) do
    case text |> String.trim() |> Integer.parse() do
      {n, ""} -> {:ok, n}
      _ -> {:error, gettext("Enter a whole number, or choose to keep forever")}
    end
  end

  # The boundaries a manual run is asked for, before the floor.
  defp run_cutoffs(form, settings) do
    now = DateTime.utc_now()

    {cutoffs, errors} =
      Enum.reduce(Retention.kinds(), {%{}, %{}}, fn kind, {cutoffs, errors} ->
        case run_cutoff(kind, form[kind], settings[kind], now) do
          {:ok, nil} -> {cutoffs, errors}
          {:ok, cut} -> {Map.put(cutoffs, kind, cut), errors}
          {:error, message} -> {cutoffs, Map.put(errors, kind, message)}
        end
      end)

    if errors == %{}, do: {:ok, cutoffs}, else: {:error, errors}
  end

  defp run_cutoff(_kind, %{"mode" => "skip"}, _saved, _now), do: {:ok, nil}

  defp run_cutoff(kind, %{"mode" => "saved"}, saved, now) do
    case Retention.cutoff(kind, saved, now) do
      {:ok, cut} -> {:ok, cut}
      _keep -> {:error, gettext("No period is saved for this kind")}
    end
  end

  defp run_cutoff(kind, value, _saved, now) do
    with {:ok, period} <- parse_n_unit(value) do
      {:ok, cut} = Retention.cutoff(kind, period, now)
      {:ok, cut}
    end
  end

  # The warnings of each kind for the periods shown: the form's where they
  # read, else the stored ones.
  defp warnings(settings), do: warnings_of(Map.new(Retention.kinds(), &{&1, nil}), settings)

  defp warnings_of(form, settings) do
    now = DateTime.utc_now()
    period = fn kind -> period_or(form[kind], settings[kind]) end
    requests = period.(:requests)

    Map.new(Retention.kinds(), fn kind ->
      {kind, Retention.warnings(kind, period.(kind), now, requests)}
    end)
  end

  defp period_or(nil, stored), do: stored

  defp period_or(value, stored) do
    case parse_period(value) do
      {:ok, period} -> period
      {:error, _message} -> stored
    end
  end
end
