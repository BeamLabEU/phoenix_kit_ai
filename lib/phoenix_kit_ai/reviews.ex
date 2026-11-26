defmodule PhoenixKitAI.Reviews do
  @moduledoc """
  A review envelope for AI results: an app puts a result in front of a
  person, who confirms or rejects it, once, and the app's own effects run on
  that decision.

      {:ok, review} =
        PhoenixKitAI.Reviews.create(%{
          kind: "listing_description",
          subject_type: "listing",
          subject_id: listing.uuid,
          request_uuid: answer["request_uuid"],
          payload: %{"description" => text}
        })

      # later, a person on AI → Reviews, or the app's own page:
      {:ok, review} = PhoenixKitAI.Reviews.confirm(review.uuid, scope: scope)

  ## Decided once

  `decide/3` (`confirm/2`, `reject/2`) moves a `pending` review to
  `confirmed` or `rejected` with one conditional `UPDATE … WHERE status =
  'pending'`, so of two people deciding at once exactly one wins; the other
  gets `{:error, {:already_decided, status}}`. A decided review never
  changes again.

  ## The app's effects: `on_decide`

  The app says what a decision does — publish the text, discard the draft —
  with a handler per kind:

      config :phoenix_kit_ai, review_handlers: %{
        "listing_description" => MyApp.ListingDescriptionReview
      }

  a module implementing `PhoenixKitAI.ReviewHandler` (`on_decide/1`, and
  optionally `summary/1` for the admin list), or for one call
  `on_decide: fun` (arity 1), which wins over the configured handler. It is
  called with the decided review **inside the decision's transaction**: `:ok`
  or `{:ok, _}` commits both, `{:error, reason}` — or a raise, throw or exit —
  rolls the decision back (`{:error, {:on_decide_failed, reason}}`; a raise is
  reported by its exception module only, a throw or exit as
  `{:thrown, :term}` / `{:exited, :term}`), so the review stays pending and
  can be decided again. Keep the handler to database work; anything slow or external (a
  mail, an API) belongs in a job the handler enqueues, which then commits or
  rolls back with the decision. A kind with no handler is decided with no
  effect.

  ## Who may decide

  With `scope:` (a `PhoenixKit.Users.Auth.Scope`) the decision needs
  `ai.manage` or an Owner, and the person is recorded; app code deciding on
  its own (a rule, a job) passes `actor_uuid:` (a user's uuid:
  `{:error, :unknown_actor}` for one that names no user) or nothing. The admin page
  (AI → Reviews) always passes the viewer's scope.

  A confirmation may carry `payload:` — the reviewer's edit — which replaces
  the payload; the first proposal stays in `metadata["proposed_payload"]`.
  `note:` is kept as `decision_note` (cut to 1 000 characters).

  Called inside a transaction of the caller's, the decision commits — or
  not — with it, but the broadcast and the Activity entry below happen when
  `decide/3` returns, before the caller's transaction commits.

  Every decision broadcasts `{:review_decided, uuid}` on
  `phoenix_kit:ai:reviews` (creation: `{:review_created, uuid}`) and writes an
  Activity entry (`review.confirmed` / `review.rejected`, the kind and the
  subject, never the payload).
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitAI.{Guard, Review}

  @topic "phoenix_kit:ai:reviews"

  @type decision :: :confirmed | :rejected

  @doc "The PubSub topic of review changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to `topic/0`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSubManager.subscribe(@topic)

  @doc """
  Puts a result up for review: `kind` (required, ≤ 100), `subject_type`
  (≤ 100), `subject_id` (≤ 255), `request_uuid`, `payload` (a map),
  `metadata` (a map). Always `pending`.
  """
  @spec create(map()) :: {:ok, Review.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    attrs
    |> Map.take(~w(kind subject_type subject_id request_uuid payload metadata))
    |> Map.update("subject_id", nil, &subject_id/1)
    |> Review.create_changeset()
    |> repo().insert()
    |> tap(fn
      {:ok, review} -> broadcast(:review_created, review.uuid)
      _ -> :ok
    end)
  end

  @doc "A review by uuid, or nil."
  @spec get(String.t()) :: Review.t() | nil
  def get(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Review, uuid)
      :error -> nil
    end
  end

  def get(_uuid), do: nil

  @doc """
  Reviews, newest first. Options: `status:` (a status or a list),
  `kind:`, `subject_type:`, `subject_id:`, `limit:` (default 50, at most 500),
  `offset:`.
  """
  @spec list(keyword()) :: [Review.t()]
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(500) |> max(1)

    opts
    |> filtered()
    |> order_by([r], desc: r.inserted_at, desc: r.uuid)
    |> limit(^limit)
    |> offset(^max(Keyword.get(opts, :offset, 0), 0))
    |> repo().all()
  end

  @doc "How many reviews match (the same filters as `list/1`)."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    opts |> filtered() |> select([r], count(r.uuid)) |> repo().one()
  end

  @doc "Confirms a pending review. See `decide/3`."
  @spec confirm(Review.t() | String.t(), keyword()) :: {:ok, Review.t()} | {:error, term()}
  def confirm(review, opts \\ []), do: decide(review, :confirmed, opts)

  @doc "Rejects a pending review. See `decide/3`."
  @spec reject(Review.t() | String.t(), keyword()) :: {:ok, Review.t()} | {:error, term()}
  def reject(review, opts \\ []), do: decide(review, :rejected, opts)

  @doc """
  Decides a pending review, once (see the moduledoc). `decision` is
  `:confirmed` or `:rejected`. Options: `scope:`, `actor_uuid:`, `note:`,
  `payload:` (on a confirmation), `on_decide:`.

  Errors: `:not_found`, `{:already_decided, status}`, `:forbidden`,
  `:unknown_actor`, `:invalid_decision`, `{:on_decide_failed, reason}`.
  """
  @spec decide(Review.t() | String.t(), decision() | String.t(), keyword()) ::
          {:ok, Review.t()} | {:error, term()}
  def decide(review, decision, opts \\ [])

  def decide(%Review{uuid: uuid}, decision, opts), do: decide(uuid, decision, opts)

  def decide(uuid, decision, opts) when is_binary(uuid) do
    with {:ok, status} <- decision(decision),
         {:ok, actor_uuid} <- actor(opts),
         {:ok, uuid} <- cast_uuid(uuid) do
      repo().transaction(fn -> decide_in_transaction(uuid, status, actor_uuid, opts) end)
      |> tap(fn
        {:ok, review} -> after_decision(review, actor_uuid)
        _ -> :ok
      end)
    end
  end

  def decide(_review, _decision, _opts), do: {:error, :not_found}

  # ── internals ─────────────────────────────────────────────────────────

  defp decide_in_transaction(uuid, status, actor_uuid, opts) do
    with {:ok, review} <- flip(uuid, status, actor_uuid, opts),
         :ok <- run_handler(review, opts) do
      review
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp filtered(opts) do
    Enum.reduce(opts, from(r in Review), fn
      {:status, statuses}, query when is_list(statuses) ->
        where(query, [r], r.status in ^statuses)

      {:status, status}, query when is_binary(status) ->
        where(query, [r], r.status == ^status)

      {:status, status}, query when is_atom(status) and not is_nil(status) ->
        where(query, [r], r.status == ^Atom.to_string(status))

      {:kind, kind}, query when is_binary(kind) ->
        where(query, [r], r.kind == ^kind)

      {:subject_type, type}, query when is_binary(type) ->
        where(query, [r], r.subject_type == ^type)

      {:subject_id, id}, query when not is_nil(id) ->
        where(query, [r], r.subject_id == ^subject_id(id))

      _other, query ->
        query
    end)
  end

  defp subject_id(nil), do: nil
  defp subject_id(id) when is_binary(id), do: id
  defp subject_id(id), do: to_string(id)

  defp decision(decision) when decision in [:confirmed, "confirmed", :confirm, "confirm"],
    do: {:ok, "confirmed"}

  defp decision(decision) when decision in [:rejected, "rejected", :reject, "reject"],
    do: {:ok, "rejected"}

  defp decision(_decision), do: {:error, :invalid_decision}

  defp actor(opts) do
    case Keyword.get(opts, :scope) do
      nil ->
        opts |> Keyword.get(:actor_uuid) |> uuid_or_nil() |> known_actor()

      %Scope{} = scope ->
        if Guard.may_manage?(scope),
          do: {:ok, scope |> Scope.user_uuid() |> uuid_or_nil()},
          else: {:error, :forbidden}

      _other ->
        {:error, :forbidden}
    end
  end

  # `decided_by_uuid` references the users: a uuid of no user would fail the
  # update with a raise.
  defp known_actor(nil), do: {:ok, nil}

  defp known_actor(uuid) do
    if repo().exists?(from(u in User, where: u.uuid == ^uuid)),
      do: {:ok, uuid},
      else: {:error, :unknown_actor}
  end

  defp uuid_or_nil(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_or_nil(_value), do: nil

  defp cast_uuid(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # The one conditional update: only a pending review moves.
  defp flip(uuid, status, actor_uuid, opts) do
    now = DateTime.utc_now()
    note = note(Keyword.get(opts, :note))

    sets = [
      status: status,
      decided_by_uuid: actor_uuid,
      decided_at: now,
      decision_note: note,
      updated_at: now
    ]

    query =
      from(r in Review, where: r.uuid == ^uuid and r.status == "pending", select: r)

    case repo().update_all(query, set: sets) do
      {1, [review]} ->
        maybe_edit_payload(review, status, Keyword.get(opts, :payload))

      {0, _} ->
        case repo().get(Review, uuid) do
          nil -> {:error, :not_found}
          %Review{status: status} -> {:error, {:already_decided, status}}
        end
    end
  end

  defp maybe_edit_payload(review, "confirmed", %{} = payload) when payload != review.payload do
    # A review is decided once, so this is the first edit: what was proposed
    # is the payload now, whatever the creator put in `metadata`.
    metadata = Map.put(review.metadata || %{}, "proposed_payload", review.payload)

    review
    |> Ecto.Changeset.change(payload: payload, metadata: metadata)
    |> repo().update()
  end

  defp maybe_edit_payload(review, _status, _payload), do: {:ok, review}

  defp note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      # In code points, as the column's CHECK (`char_length`) counts.
      text -> text |> String.codepoints() |> Enum.take(Review.note_max()) |> Enum.join()
    end
  end

  defp note(_note), do: nil

  defp run_handler(review, opts) do
    case handler(review, opts) do
      nil ->
        :ok

      fun ->
        case fun |> call_handler(review) |> handler_result() do
          :ok -> :ok
          {:error, reason} -> {:error, {:on_decide_failed, reason}}
        end
    end
  end

  defp handler(review, opts) do
    case Keyword.get(opts, :on_decide) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        case review_handler(review.kind) do
          nil -> nil
          module -> &module.on_decide/1
        end
    end
  end

  @doc """
  The handler module configured for `kind` (`config :phoenix_kit_ai,
  review_handlers: %{kind => module}`), or nil. A configured module that
  does not export `on_decide/1` is ignored with a warning.
  """
  @spec review_handler(String.t()) :: module() | nil
  def review_handler(kind) do
    handlers = Application.get_env(:phoenix_kit_ai, :review_handlers, %{})
    handlers = if is_map(handlers) or is_list(handlers), do: Map.new(handlers), else: %{}

    case Map.get(handlers, kind) do
      module when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :on_decide, 1) do
          module
        else
          Logger.warning(
            "[PhoenixKitAI.Reviews] review handler for #{inspect(kind)} has no on_decide/1"
          )

          nil
        end

      _ ->
        nil
    end
  end

  # A raise in the app's code rolls the decision back like an error; only
  # the exception's module is reported (its message may carry data).
  defp call_handler(fun, review) do
    fun.(review)
  rescue
    error -> {:error, {:raised, error.__struct__}}
  catch
    :throw, _value -> {:error, {:thrown, :term}}
    :exit, _reason -> {:error, {:exited, :term}}
  end

  defp handler_result(:ok), do: :ok
  defp handler_result({:ok, _}), do: :ok
  defp handler_result({:error, reason}), do: {:error, reason}
  defp handler_result(other), do: {:error, {:unexpected_return, shape(other)}}

  defp shape(value) when is_tuple(value) and tuple_size(value) > 0 and is_atom(elem(value, 0)),
    do: elem(value, 0)

  defp shape(value) when is_atom(value), do: value
  defp shape(_value), do: :term

  defp after_decision(review, actor_uuid) do
    broadcast(:review_decided, review.uuid)

    PhoenixKit.Activity.log("ai", "review.#{review.status}",
      mode: if(actor_uuid, do: "manual", else: "auto"),
      actor_uuid: actor_uuid,
      resource_type: "ai_review",
      resource_uuid: review.uuid,
      metadata: %{
        "kind" => review.kind,
        "subject_type" => review.subject_type,
        "subject_id" => review.subject_id
      }
    )
  end

  defp broadcast(event, uuid) do
    PubSubManager.broadcast(@topic, {event, uuid})
  rescue
    _ -> :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
