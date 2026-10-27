defmodule PhoenixKitAI.VisionBatch do
  @moduledoc """
  One vision verb over many items: `PhoenixKitAI.vision_batch/3`.

  Each item runs as its own call of the chosen verb — through the same
  gate, spend caps, task limits, cache, limiter and usage rows as a single
  call — and comes back with its own status, so one bad image never fails
  the batch and never yields made-up output: a failed or unparsed answer is
  an error for that item, with no result.

  Items run `concurrency:` at a time (default 4; the per-provider
  `PhoenixKitAI.Limiter` still applies across the whole node). A batch
  stops starting new items — the rest come back `:skipped` — when:

  * the money spent reaches `budget:` (dollars, a `Decimal` or a decimal
    string; items already running finish, so a batch overshoots by at most
    its in-flight items; `0` starts nothing). Only priced calls count: an
    item whose call has no cost — a provider reporting none, for a model
    no price is known for — spends nothing as far as the budget can tell,
    or
  * an item is refused for a reason every later item would hit too: a
    spend cap, a task limit, a switched-off or blocked task, an unfit model,
    an exhausted provider balance, a bad key, a missing or disabled
    endpoint, an endpoint with no model or connection. When an item's own
    `opts:` change who asks or what runs (`user_uuid:`, `task:`, `model:`,
    `models:`), only the refusals that do not depend on those stop the
    batch — an exhausted balance, a bad key, the site's or the endpoint's
    spend cap.

  Items run unlinked under core's `PhoenixKit.TaskSupervisor` when it is
  running (a crashed item is an error for that item, not a crash of the
  caller), else as linked tasks.

  All calls carry `run:` (the caller's, else a generated `"batch-<uuid>"`)
  and `step:` (the caller's, else the verb's name), so
  `PhoenixKitAI.run_costs/2` totals the batch afterwards. An `:unparsed`
  item carries the cost its answer was billed, and that counts toward the
  budget; a cache hit costs nothing.
  """

  alias PhoenixKitAI.{Guard, Money}

  @verbs [:describe_image, :extract_text, :detect_regions, :check_statements]

  # Batch options; everything else is passed on to every call.
  @batch_keys [:verb, :concurrency, :budget, :item_timeout, :labels]

  @default_concurrency 4
  @max_concurrency 32
  @default_item_timeout 300_000

  # Refusals every later item of the batch would get too.
  @fatal_atoms [
    :endpoint_not_found,
    :endpoint_disabled,
    :invalid_endpoint_identifier,
    :invalid_api_key,
    :api_key_forbidden,
    :insufficient_credits,
    :money_migration_required,
    :model_not_found,
    :endpoint_no_model,
    :integration_deleted,
    :integration_not_configured
  ]

  # The fatal refusals that hold whoever asks and whatever runs: these stop
  # a batch even when items override `user_uuid:`, `task:` or `model:`.
  @account_atoms [
    :endpoint_not_found,
    :endpoint_disabled,
    :invalid_endpoint_identifier,
    :invalid_api_key,
    :api_key_forbidden,
    :insufficient_credits,
    :money_migration_required,
    :endpoint_no_model,
    :integration_deleted,
    :integration_not_configured
  ]

  # Item options that change who asks or what runs.
  @scope_keys [:user_uuid, :task, :model, :models, :guard_admission]
  @fatal_tags [
    :budget_exceeded,
    :budget_unmigrated,
    :task_limit_exceeded,
    :task_limit_unmigrated,
    :task_disabled,
    :task_blocked,
    :model_unfit,
    :model_unverified
  ]

  @type item_status :: :ok | :error | :unparsed | :skipped

  @type item_result :: %{
          id: term(),
          status: item_status(),
          result: map() | nil,
          error: term() | nil,
          cost: Decimal.t() | nil
        }

  @type t :: %{
          run: String.t(),
          verb: atom(),
          items: [item_result()],
          cost: Decimal.t(),
          counts: %{required(item_status()) => non_neg_integer()},
          stopped: nil | :budget | {:error, term()}
        }

  @doc "The verbs a batch can run."
  @spec verbs() :: [atom()]
  def verbs, do: @verbs

  @doc "Runs the batch. See `PhoenixKitAI.vision_batch/3`."
  @spec run(term(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def run(endpoint, items, opts \\ []) do
    verb = Keyword.get(opts, :verb, :describe_image)

    with :ok <- check_verb(verb),
         {:ok, items} <- normalize_items(items),
         {:ok, budget} <- budget(opts[:budget]),
         {:ok, endpoint} <- PhoenixKitAI.resolve_endpoint(endpoint) do
      run_tag = Guard.run_tag(opts[:run]) || "batch-" <> UUIDv7.generate()
      step = Guard.run_tag(opts[:step]) || Atom.to_string(verb)

      call_opts =
        opts
        |> Keyword.drop(@batch_keys)
        |> Keyword.merge(run: run_tag, step: step)

      # A zero budget starts nothing.
      initial_stop = if budget && Decimal.compare(budget, 0) != :gt, do: :budget
      {:ok, state} = Agent.start_link(fn -> %{spent: Decimal.new(0), stop: initial_stop} end)

      try do
        results =
          items
          |> stream(
            fn item -> run_item(item, verb, endpoint, call_opts, opts, budget, state) end,
            max_concurrency: concurrency(opts[:concurrency]),
            ordered: true,
            timeout: item_timeout(opts[:item_timeout]),
            on_timeout: :kill_task
          )
          |> Enum.zip(items)
          |> Enum.map(fn
            {{:ok, result}, _item} ->
              result

            {{:exit, :timeout}, item} ->
              item_result(item.id, :error, nil, :item_timeout, nil)

            {{:exit, reason}, item} ->
              item_result(item.id, :error, nil, {:item_exit, exit_tag(reason)}, nil)
          end)

        %{stop: stop} = Agent.get(state, & &1)

        {:ok,
         %{
           run: run_tag,
           verb: verb,
           items: results,
           cost:
             results
             |> Enum.map(& &1.cost)
             |> Enum.reject(&is_nil/1)
             |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
           counts: counts(results),
           stopped: stop
         }}
      after
        Agent.stop(state)
      end
    end
  end

  # Unlinked under core's task supervisor when it runs, so an item that
  # dies in a way `rescue`/`catch` cannot see (a kill, a crashing linked
  # child) is an `{:exit, reason}` for that item, not the caller's death.
  defp stream(items, fun, opts) do
    case Process.whereis(PhoenixKit.TaskSupervisor) do
      pid when is_pid(pid) -> Task.Supervisor.async_stream_nolink(pid, items, fun, opts)
      nil -> Task.async_stream(items, fun, opts)
    end
  end

  defp run_item(item, verb, endpoint, call_opts, opts, budget, state) do
    if Agent.get(state, & &1.stop) do
      item_result(item.id, :skipped, nil, nil, nil)
    else
      _ = PhoenixKitAI.take_unparsed_cost()

      outcome =
        try do
          call(verb, endpoint, item, call_opts, opts)
        rescue
          exception -> {:error, {:exception, exception.__struct__}}
        catch
          kind, _reason -> {:error, {:exception, kind}}
        end

      result = to_item_result(item.id, outcome)

      # An unparsed answer was billed: its cost counts toward the budget.
      result =
        if result.status == :unparsed,
          do: %{result | cost: PhoenixKitAI.take_unparsed_cost()},
          else: result

      record(state, result, budget, scoped?(item))
      result
    end
  end

  defp call(:describe_image, endpoint, item, call_opts, _opts),
    do: PhoenixKitAI.describe_image(endpoint, item.images, item_opts(item, call_opts))

  defp call(:extract_text, endpoint, item, call_opts, _opts),
    do: PhoenixKitAI.extract_text(endpoint, item.images, item_opts(item, call_opts))

  defp call(:detect_regions, endpoint, item, call_opts, opts),
    do:
      PhoenixKitAI.detect_regions(
        endpoint,
        item.images,
        Map.get(item, :labels) || opts[:labels],
        item_opts(item, call_opts)
      )

  defp call(:check_statements, endpoint, item, call_opts, _opts),
    do:
      PhoenixKitAI.check_statements(
        endpoint,
        Map.get(item, :statements) || [],
        item.images,
        item_opts(item, call_opts)
      )

  # An item's own `prompt:` and `opts:` go over the batch's.
  defp item_opts(item, call_opts) do
    call_opts
    |> then(fn o -> if item[:prompt], do: Keyword.put(o, :prompt, item.prompt), else: o end)
    |> Keyword.merge(Map.get(item, :opts) || [])
  end

  defp to_item_result(id, {:ok, result}), do: item_result(id, :ok, result, nil, result[:cost])

  defp to_item_result(id, {:error, {:no_json_in_response, _} = reason}),
    do: item_result(id, :unparsed, nil, reason, nil)

  defp to_item_result(id, {:error, reason}), do: item_result(id, :error, nil, reason, nil)

  defp item_result(id, status, result, error, cost),
    do: %{id: id, status: status, result: result, error: error, cost: cost}

  defp record(state, result, budget, scoped?) do
    Agent.update(state, fn st ->
      spent = if result.cost, do: Decimal.add(st.spent, result.cost), else: st.spent

      stop =
        cond do
          st.stop -> st.stop
          result.status == :error and fatal?(result.error, scoped?) -> {:error, result.error}
          budget && Decimal.compare(spent, budget) != :lt -> :budget
          true -> nil
        end

      %{st | spent: spent, stop: stop}
    end)
  end

  # Only the shape of an exit reason, never its terms (they can carry data).
  defp exit_tag({tag, _}) when is_atom(tag), do: tag
  defp exit_tag(tag) when is_atom(tag), do: tag
  defp exit_tag(_reason), do: :unknown

  # An item that overrides who asks or what runs may be refused for its own
  # sake (that user's cap, that model's fitness): only account-wide
  # refusals stop the batch then.
  defp fatal?(reason, true), do: account_wide?(reason)
  defp fatal?(reason, false) when reason in @fatal_atoms, do: true
  defp fatal?(reason, false) when is_tuple(reason) and elem(reason, 0) in @fatal_tags, do: true
  defp fatal?(_reason, false), do: false

  defp account_wide?(reason) when reason in @account_atoms, do: true
  defp account_wide?({:budget_exceeded, scope}) when scope in [:global, :endpoint], do: true
  defp account_wide?(_reason), do: false

  defp scoped?(item) do
    case Map.get(item, :opts) do
      opts when is_list(opts) -> Enum.any?(@scope_keys, &Keyword.has_key?(opts, &1))
      _ -> false
    end
  end

  defp counts(results) do
    base = %{ok: 0, error: 0, unparsed: 0, skipped: 0}
    Enum.reduce(results, base, fn r, acc -> Map.update!(acc, r.status, &(&1 + 1)) end)
  end

  defp check_verb(verb) when verb in @verbs, do: :ok
  defp check_verb(verb), do: {:error, {:unsupported_batch_verb, verb}}

  # An item is `%{id:, images:}` (plus `:prompt`, `:labels`, `:statements`,
  # `:opts`), `{id, images}`, or the images alone (its index is its id).
  defp normalize_items(items) when is_list(items) do
    {:ok,
     items
     |> Enum.with_index()
     |> Enum.map(fn
       {%{images: images} = item, index} ->
         item |> Map.put(:images, images) |> Map.put_new(:id, index)

       {{id, images}, _index} ->
         %{id: id, images: images}

       {images, index} ->
         %{id: index, images: images}
     end)}
  end

  defp normalize_items(_items), do: {:error, :invalid_batch_items}

  defp budget(nil), do: {:ok, nil}

  defp budget(value) do
    case Money.amount(value) do
      {:ok, amount} -> {:ok, amount}
      {:error, reason} -> {:error, {:invalid_budget, reason}}
      :error -> {:error, {:invalid_budget, :not_an_amount}}
    end
  end

  defp concurrency(n) when is_integer(n) and n > 0, do: min(n, @max_concurrency)
  defp concurrency(_n), do: @default_concurrency

  defp item_timeout(ms) when is_integer(ms) and ms > 0, do: ms
  defp item_timeout(:infinity), do: :infinity
  defp item_timeout(_ms), do: @default_item_timeout
end
