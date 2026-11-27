defmodule PhoenixKitAI.Web.Reviews do
  @moduledoc """
  LiveView of the review envelope (`PhoenixKitAI.Reviews`): the AI results
  apps have put up for a person's word, newest first, filtered by status
  (pending by default) and kind. Every holder of the base `ai` permission
  sees the list; confirming or rejecting needs `ai.review` or `ai.manage`
  (or an Owner),
  checked again on every event against the scope as it is now
  (`PhoenixKitAI.Web.Access`) and once more by `Reviews.decide/3`. A
  decision runs the app's `on_decide` handler for the kind; when the handler
  refuses, the review stays pending and the page says so.

  Mounted at `{prefix}/admin/ai/reviews`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitAI.Gettext

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitAI.{Review, Reviews}
  alias PhoenixKitAI.Web.Access
  alias PhoenixKitAI.Web.MessageShape

  @page_size 50
  @statuses ~w(pending confirmed rejected all)
  @payload_preview 400

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Reviews.subscribe()

    socket =
      socket
      |> Access.assign_session(session)
      |> assign(:current_path, PhoenixKitAI.Routes.ai_path() <> "/reviews")
      |> assign(:page_section, gettext("AI"))
      |> assign(:page_section_path, PhoenixKitAI.Routes.ai_path())
      |> assign(:page_crumbs, [])
      |> assign(:page_title, gettext("Reviews"))
      |> assign(
        :page_subtitle,
        gettext("AI results waiting for a person to confirm or reject them")
      )
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:can_manage, false)
      |> assign(:status, "pending")
      |> assign(:kind, nil)
      |> assign(:reviews, [])
      |> assign(:total, 0)
      |> assign(:pending_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "pending"
    kind = if is_binary(params["kind"]) and params["kind"] != "", do: params["kind"]

    {:noreply,
     socket
     |> assign(:current_path, URI.parse(uri).path)
     |> assign(:status, status)
     |> assign(:kind, kind)
     |> assign(:can_manage, Access.may_review?(socket))
     |> load()}
  end

  @doc "Recomputes the right to decide when core updates the viewer's scope."
  @spec phoenix_kit_scope_changed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def phoenix_kit_scope_changed(socket),
    do: assign(socket, :can_manage, Access.may_review?(socket))

  @impl true
  def handle_event("decide", %{"uuid" => uuid, "decision" => decision} = params, socket)
      when decision in ["confirmed", "rejected"] do
    case Access.review_scope(socket) do
      {:ok, scope} ->
        result = Reviews.decide(uuid, decision, scope: scope, note: params["note"])
        {:noreply, socket |> flash_result(result) |> load()}

      :error ->
        {:noreply,
         socket
         |> assign(:can_manage, false)
         |> put_flash(:error, gettext("You may not decide AI reviews"))}
    end
  end

  def handle_event("decide", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({event, _uuid}, socket) when event in [:review_created, :review_decided],
    do: {:noreply, load(socket)}

  def handle_info(msg, socket) do
    Logger.debug("[PhoenixKitAI.Web.Reviews] unhandled message: #{MessageShape.describe(msg)}")
    {:noreply, socket}
  end

  defp flash_result(socket, {:ok, %Review{status: "confirmed"}}),
    do: put_flash(socket, :info, gettext("Review confirmed"))

  defp flash_result(socket, {:ok, %Review{}}),
    do: put_flash(socket, :info, gettext("Review rejected"))

  defp flash_result(socket, {:error, {:already_decided, _status}}),
    do: put_flash(socket, :error, gettext("This review has already been decided"))

  defp flash_result(socket, {:error, {:on_decide_failed, _reason}}),
    do:
      put_flash(
        socket,
        :error,
        gettext("The app could not apply this decision; the review is still pending")
      )

  defp flash_result(socket, {:error, :forbidden}),
    do: put_flash(socket, :error, gettext("You may not decide AI reviews"))

  defp flash_result(socket, {:error, _reason}),
    do: put_flash(socket, :error, gettext("The review could not be decided"))

  defp load(socket) do
    filters =
      [kind: socket.assigns.kind]
      |> then(fn f ->
        if socket.assigns.status == "all", do: f, else: [{:status, socket.assigns.status} | f]
      end)

    socket
    |> assign(:reviews, Reviews.list(Keyword.put(filters, :limit, @page_size)))
    |> assign(:total, Reviews.count(filters))
    |> assign(:pending_count, Reviews.count(status: "pending"))
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitAI.Web.Reviews] reviews not loaded: #{inspect(error.__struct__)}"
      )

      socket |> assign(:reviews, []) |> assign(:total, 0)
  end

  defp status_label("pending"), do: gettext("Pending")
  defp status_label("confirmed"), do: gettext("Confirmed")
  defp status_label("rejected"), do: gettext("Rejected")
  defp status_label("all"), do: gettext("All")

  defp review_badge_class("pending"), do: "badge-warning"
  defp review_badge_class("confirmed"), do: "badge-success"
  defp review_badge_class(_), do: "badge-ghost"

  defp filter_path(status, kind) do
    query =
      URI.encode_query(Enum.reject([status: status, kind: kind], fn {_, v} -> is_nil(v) end))

    PhoenixKitAI.Routes.ai_path() <> "/reviews?" <> query
  end

  @doc false
  # The one line a row shows: the kind's handler's `summary/1`, else the
  # payload as JSON, cut.
  @spec summary(Review.t()) :: String.t()
  def summary(%Review{kind: kind} = review) do
    with module when not is_nil(module) <- Reviews.review_handler(kind),
         true <- function_exported?(module, :summary, 1),
         text when is_binary(text) <- safe_summary(module, review) do
      text
    else
      _ -> payload_preview(review.payload)
    end
  end

  defp safe_summary(module, review) do
    module.summary(review)
  rescue
    _ -> nil
  end

  defp payload_preview(payload) do
    text = Jason.encode!(payload || %{})

    if String.length(text) > @payload_preview,
      do: String.slice(text, 0, @payload_preview) <> "…",
      else: text
  rescue
    _ -> ""
  end

  defp when_text(nil), do: ""
  defp when_text(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp when_text(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :statuses, @statuses)

    ~H"""
    <div class="flex flex-col gap-4" id="ai-reviews">
      <div class="flex flex-wrap items-center gap-2">
        <div role="tablist" class="tabs tabs-boxed">
          <.link
            :for={status <- @statuses}
            patch={filter_path(status, @kind)}
            role="tab"
            id={"ai-reviews-filter-#{status}"}
            class={["tab", @status == status && "tab-active"]}
          >
            {status_label(status)}
            <span :if={status == "pending" and @pending_count > 0} class="badge badge-sm ml-1">
              {PhoenixKitAI.Numbers.integer(@pending_count)}
            </span>
          </.link>
        </div>
        <span :if={@kind} class="badge badge-outline gap-1">
          {@kind}
          <.link patch={filter_path(@status, nil)} aria-label={gettext("Show every kind")}>×</.link>
        </span>
      </div>

      <p :if={not @can_manage} id="ai-reviews-read-only" class="text-sm text-base-content/70">
        {gettext("You can see the reviews; deciding them needs the permission to decide AI reviews.")}
      </p>

      <p :if={@reviews == []} id="ai-reviews-empty" class="text-base-content/70">
        {gettext("No reviews here.")}
      </p>

      <div
        :for={review <- @reviews}
        id={"ai-review-#{review.uuid}"}
        data-status={review.status}
        class="card bg-base-100 shadow-sm"
      >
        <div class="card-body gap-2 p-4">
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class={["badge", review_badge_class(review.status)]}>{status_label(review.status)}</span>
            <.link patch={filter_path(@status, review.kind)} class="font-medium link link-hover">
              {review.kind}
            </.link>
            <span :if={review.subject_type || review.subject_id} class="text-base-content/70">
              {review.subject_type} {review.subject_id}
            </span>
            <span class="ml-auto text-base-content/60">{when_text(review.inserted_at)}</span>
          </div>

          <p class="text-sm break-words whitespace-pre-line" data-summary>{summary(review)}</p>

          <p :if={review.status != "pending"} class="text-xs text-base-content/60">
            {gettext("Decided %{at}", at: when_text(review.decided_at))}
            <span :if={review.decision_note}>— {review.decision_note}</span>
          </p>

          <form
            :if={@can_manage and review.status == "pending"}
            phx-submit="decide"
            class="flex flex-wrap items-center gap-2"
            id={"ai-review-form-#{review.uuid}"}
          >
            <input type="hidden" name="uuid" value={review.uuid} />
            <input
              type="text"
              name="note"
              maxlength="1000"
              class="input input-sm input-bordered flex-1 min-w-48"
              placeholder={gettext("Note (optional)")}
            />
            <button type="submit" name="decision" value="confirmed" class="btn btn-sm btn-success">
              {gettext("Confirm")}
            </button>
            <button type="submit" name="decision" value="rejected" class="btn btn-sm btn-ghost">
              {gettext("Reject")}
            </button>
          </form>
        </div>
      </div>

      <p :if={@total > length(@reviews)} class="text-sm text-base-content/60">
        {gettext("Showing the newest %{shown} of %{total}.",
          shown: PhoenixKitAI.Numbers.integer(length(@reviews)),
          total: PhoenixKitAI.Numbers.integer(@total)
        )}
      </p>
    </div>
    """
  end
end
