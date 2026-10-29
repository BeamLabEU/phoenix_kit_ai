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
    `models:`, `fallback_models:`), only the refusals that do not depend on those stop the
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

  require Logger

  alias PhoenixKitAI.{Guard, Money}

  @verbs [:describe_image, :extract_text, :detect_regions, :check_statements]

  # Batch options; everything else is passed on to every call.
  @batch_keys [:verb, :concurrency, :budget, :item_timeout, :labels, :group]
  @max_group 8

  @default_concurrency 4
  @max_concurrency 32
  @default_item_timeout 300_000

  # Refusals every later item of the batch would get too.
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

  # Refusals every later item of the batch would get too: the account-wide
  # ones, and a model the provider does not serve.
  @fatal_atoms @account_atoms ++ [:model_not_found]

  # Item options that change who asks or what runs.
  @scope_keys [:user_uuid, :task, :model, :models, :fallback_models, :guard_admission]
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
         {:ok, group} <- check_group(opts, verb),
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

      {:ok, state} =
        Agent.start_link(fn ->
          %{
            spent: Decimal.new(0),
            stop: initial_stop,
            scoped?: Enum.any?(items, &scoped?/1)
          }
        end)

      units = units(items, group, PhoenixKitAI.Images.max_total_input_bytes(call_opts))

      try do
        flat =
          units
          |> stream(
            fn unit -> run_unit(unit, verb, endpoint, call_opts, opts, budget, state) end,
            max_concurrency: concurrency(opts[:concurrency]),
            ordered: true,
            timeout: unit_timeout(opts[:item_timeout], group),
            on_timeout: :kill_task
          )
          |> Enum.zip(units)
          |> Enum.flat_map(fn
            {{:ok, results}, _unit} ->
              results

            {{:exit, :timeout}, unit} ->
              Enum.map(unit, &item_result(&1.id, :error, nil, :item_timeout, nil))

            {{:exit, reason}, unit} ->
              Enum.map(
                unit,
                &item_result(&1.id, :error, nil, {:item_exit, exit_tag(reason)}, nil)
              )
          end)

        # Back in the order the items were given (a unit's results follow its items).
        results =
          units
          |> List.flatten()
          |> Enum.zip(flat)
          |> Enum.sort_by(fn {item, _} -> item.index end)
          |> Enum.map(fn {_, r} -> r end)

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

  # A unit is one item, or (`group: n`) up to n plain items asked in one call.
  defp run_unit([item], verb, endpoint, call_opts, opts, budget, state),
    do: [run_item(item, verb, endpoint, call_opts, opts, budget, state)]

  defp run_unit(group, :describe_image, endpoint, call_opts, opts, budget, state) do
    if Agent.get(state, & &1.stop) do
      Enum.map(group, &item_result(&1.id, :skipped, nil, nil, nil))
    else
      _ = PhoenixKitAI.take_unparsed_cost()
      images = Enum.flat_map(group, &List.wrap(&1.images))

      outcome =
        safely(fn ->
          PhoenixKitAI.describe_image(endpoint, images, group_opts(group, call_opts, opts))
        end)

      results = group_results(group, outcome, opts)
      # Billed but unusable answers in this unit (failed fallback attempts), shared like the call.
      results = add_shares(results, PhoenixKitAI.take_unparsed_cost())
      Enum.each(results, &record(state, &1, budget))
      results
    end
  end

  # Items that carry their own prompt or options run alone; the rest are
  # packed `group` at a time, in order, and a group closes early rather
  # than carry more image bytes than one call may (items that would each
  # pass alone must not fail together).
  defp units(items, 1, _max_bytes), do: Enum.map(items, &[&1])

  defp units(items, group, max_bytes) do
    {plain, own} =
      Enum.split_with(items, &(not Map.has_key?(&1, :prompt) and not Map.has_key?(&1, :opts)))

    packed =
      Enum.chunk_while(
        plain,
        {[], 0},
        fn item, {acc, bytes} ->
          size = PhoenixKitAI.Images.input_bytes(item.images)

          cond do
            acc == [] ->
              {:cont, {[item], size}}

            length(acc) < group and bytes + size <= max_bytes ->
              {:cont, {[item | acc], bytes + size}}

            true ->
              {:cont, Enum.reverse(acc), {[item], size}}
          end
        end,
        fn
          {[], _} -> {:cont, {[], 0}}
          {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
        end
      )

    packed ++ Enum.map(own, &[&1])
  end

  defp group_opts(group, call_opts, opts) do
    {lines, _next} =
      group
      |> Enum.with_index(1)
      |> Enum.map_reduce(1, fn {item, k}, first ->
        c = length(List.wrap(item.images))
        imgs = if c == 1, do: "image #{first}", else: "images #{first}-#{first + c - 1}"
        {"item #{k} = #{imgs}", first + c}
      end)

    base = opts[:prompt] || PhoenixKitAI.Images.default_question()

    prompt =
      "This request covers #{length(group)} separate items, each with its own images: " <>
        Enum.join(lines, "; ") <>
        ". Do the following for EACH item on its own, using only that item's images, and " <>
        "answer once per item in `items`, with its number in `item`:\n\n" <> base

    call_opts
    |> Keyword.drop([:json, :schema, :prompt])
    |> Keyword.merge(prompt: prompt, schema: group_schema(opts[:schema]))
    |> scale_max_tokens(length(group))
  end

  defp group_schema(item_schema) do
    answer =
      case item_schema do
        %{} = schema -> schema
        _ -> %{"type" => "string", "description" => "The answer for this item"}
      end

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["items"],
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["item", "answer"],
            "properties" => %{
              "item" => %{
                "type" => "integer",
                "description" => "The item's number, 1 = the first"
              },
              "answer" => answer
            }
          }
        }
      }
    }
  end

  defp scale_max_tokens(opts, n) do
    case opts[:max_tokens] do
      m when is_integer(m) -> Keyword.put(opts, :max_tokens, m * n)
      _ -> opts
    end
  end

  # One result per item of the group. The call's cost is shared equally; an
  # answer the call left out, or gave in the wrong shape, is an error for
  # that item only.
  defp group_results(group, {:ok, result}, opts) do
    n = length(group)
    share = share(result[:cost], n)
    answers = group_answers(result.json, n)

    group
    |> Enum.with_index(1)
    |> Enum.map(fn {item, k} ->
      with {:ok, a} <- Map.fetch(answers, k),
           true <- answer_fits?(a, opts[:schema]) do
        item_result(item.id, :ok, grouped_answer(a, result, share, n, opts), nil, share)
      else
        _ ->
          # The call was paid for this item too: it keeps its share.
          item_result(item.id, :error, nil, :missing_in_group, share)
      end
    end)
  end

  # Billed but unusable: the cost is added per item by `add_shares/2`.
  defp group_results(group, {:error, {tag, _} = reason}, _opts)
       when tag in [:no_json_in_response, :output_truncated] do
    Enum.map(group, &item_result(&1.id, :unparsed, nil, reason, nil))
  end

  defp group_results(group, {:error, reason}, _opts),
    do: Enum.map(group, &item_result(&1.id, :error, nil, reason, nil))

  # The answers by item number. Strict schemas cannot bound `item` (Anthropic
  # refuses `minimum`), so a model that counts from 0 is read as such when
  # its numbers are exactly 0..n-1; a number given twice answers neither.
  defp group_answers(%{"items" => entries}, n) when is_list(entries) do
    pairs = for %{"item" => k, "answer" => a} <- entries, is_integer(k), do: {k, a}
    keys = Enum.map(pairs, &elem(&1, 0))
    shift = if Enum.sort(keys) == Enum.to_list(0..(n - 1)//1), do: 1, else: 0
    twice = keys |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Map.new()

    for {k, a} <- pairs, not Map.has_key?(twice, k), into: %{}, do: {k + shift, a}
  end

  defp group_answers(_json, _n), do: %{}

  # No schema asks for a text answer; an object or array schema for that.
  defp answer_fits?(a, schema) when not is_map(schema), do: is_binary(a)
  defp answer_fits?(a, %{"type" => "object"}), do: is_map(a)
  defp answer_fits?(a, %{type: "object"}), do: is_map(a)
  defp answer_fits?(a, %{"type" => "array"}), do: is_list(a)
  defp answer_fits?(a, %{type: "array"}), do: is_list(a)
  defp answer_fits?(a, %{"type" => "string"}), do: is_binary(a)
  defp answer_fits?(a, %{type: "string"}), do: is_binary(a)
  defp answer_fits?(a, _schema), do: not is_nil(a)

  defp grouped_answer(answer, result, share, n, opts) do
    {text, json} =
      if is_map(opts[:schema]), do: {nil, answer}, else: {if(is_binary(answer), do: answer), nil}

    base = %{
      text: text,
      json: json,
      model: result.model,
      request_uuid: result[:request_uuid],
      cost: share,
      group_size: n
    }

    if result[:fallbacks], do: Map.put(base, :fallbacks, result.fallbacks), else: base
  end

  defp add_shares(results, nil), do: results

  defp add_shares(results, %Decimal{} = extra) do
    each = share(extra, length(results))
    Enum.map(results, &%{&1 | cost: add(&1.cost, each)})
  end

  defp add(nil, b), do: b
  defp add(a, nil), do: a
  defp add(a, b), do: Decimal.add(a, b)

  defp share(nil, _n), do: nil
  defp share(%Decimal{} = cost, n), do: Decimal.div(cost, n)

  defp check_group(opts, verb) do
    case Keyword.get(opts, :group, 1) do
      1 -> {:ok, 1}
      n when is_integer(n) and n > 1 and n <= @max_group -> groupable(n, verb, opts)
      other -> {:error, {:unsupported_option, :group, other}}
    end
  end

  defp groupable(_n, verb, _opts) when verb != :describe_image,
    do: {:error, {:unsupported_option, :group, verb}}

  defp groupable(n, _verb, opts) do
    cond do
      opts[:json] == true and not is_map(opts[:schema]) ->
        {:error, {:unsupported_option, :group, :json_without_schema}}

      opts[:regions] not in [nil, false, []] ->
        {:error, {:unsupported_option, :group, :regions}}

      true ->
        {:ok, n}
    end
  end

  defp unit_timeout(ms, group) do
    case item_timeout(ms) do
      :infinity -> :infinity
      t -> t * group
    end
  end

  defp run_item(item, verb, endpoint, call_opts, opts, budget, state) do
    if Agent.get(state, & &1.stop) do
      item_result(item.id, :skipped, nil, nil, nil)
    else
      _ = PhoenixKitAI.take_unparsed_cost()

      outcome =
        safely(fn -> call(verb, endpoint, item, call_opts, opts) end)

      result = to_item_result(item.id, outcome)

      # Unusable answers were billed (an unparsed or cut-off answer, a failed
      # fallback attempt, a failed confirmation): their cost counts toward the
      # budget and the item's cost, on top of what the answer itself cost.
      result = %{result | cost: add(result.cost, PhoenixKitAI.take_unparsed_cost())}

      record(state, result, budget)
      result
    end
  end

  defp call(:describe_image, endpoint, item, call_opts, _opts),
    do:
      PhoenixKitAI.describe_image(
        endpoint,
        item.images,
        item_opts(item, call_opts, :describe_image)
      )

  defp call(:extract_text, endpoint, item, call_opts, _opts),
    do:
      PhoenixKitAI.extract_text(endpoint, item.images, item_opts(item, call_opts, :extract_text))

  defp call(:detect_regions, endpoint, item, call_opts, opts),
    do:
      PhoenixKitAI.detect_regions(
        endpoint,
        item.images,
        Map.get(item, :labels) || opts[:labels],
        item_opts(item, call_opts, :detect_regions)
      )

  defp call(:check_statements, endpoint, item, call_opts, _opts),
    do:
      PhoenixKitAI.check_statements(
        endpoint,
        Map.get(item, :statements) || [],
        item.images,
        item_opts(item, call_opts, :check_statements)
      )

  # An item's own `prompt:` and `opts:` go over the batch's. For the verbs
  # with a fixed prompt of their own, an item's `prompt:` is added to it as
  # `instructions:` instead of being silently replaced.
  defp item_opts(item, call_opts, verb) do
    call_opts
    |> then(fn o ->
      case {item[:prompt], verb} do
        {nil, _} -> o
        {p, :describe_image} -> Keyword.put(o, :prompt, p)
        {p, _} -> Keyword.put(o, :instructions, p)
      end
    end)
    |> Keyword.merge(Map.get(item, :opts) || [])
  end

  # One item must not fail the batch, so a crash in its call is an error for
  # that item — logged with the exception's module and stack only (its message
  # and terms can carry the item's data), so a programming error still shows.
  defp safely(fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "[PhoenixKitAI.VisionBatch] item crashed: " <>
          inspect(exception.__struct__) <> "\n" <> safe_stacktrace(__STACKTRACE__)
      )

      {:error, {:exception, exception.__struct__}}
  catch
    kind, _reason ->
      Logger.error("[PhoenixKitAI.VisionBatch] item exited: #{kind}")
      {:error, {:exception, kind}}
  end

  # Erlang exception frames may carry argument values rather than an arity.
  # Keep the call sites for diagnosis without formatting those values.
  defp safe_stacktrace(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
    |> Exception.format_stacktrace()
  end

  defp to_item_result(id, {:ok, result}), do: item_result(id, :ok, result, nil, result[:cost])

  # Answered and billed, but unusable: not JSON, or cut off at the output limit.
  defp to_item_result(id, {:error, {tag, _} = reason})
       when tag in [:no_json_in_response, :output_truncated],
       do: item_result(id, :unparsed, nil, reason, nil)

  defp to_item_result(id, {:error, reason}), do: item_result(id, :error, nil, reason, nil)

  defp item_result(id, status, result, error, cost),
    do: %{id: id, status: status, result: result, error: error, cost: cost}

  defp record(state, result, budget) do
    Agent.update(state, fn st ->
      spent = if result.cost, do: Decimal.add(st.spent, result.cost), else: st.spent

      stop =
        cond do
          st.stop -> st.stop
          result.status == :error and fatal?(result.error, st.scoped?) -> {:error, result.error}
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

  # If any item overrides who asks or what runs, even a refusal of the batch's
  # default user/model need not apply to the other items. Only account-wide
  # refusals stop that batch.
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
         item |> Map.put(:images, images) |> Map.put_new(:id, index) |> Map.put(:index, index)

       {{id, images}, index} ->
         %{id: id, images: images, index: index}

       {images, index} ->
         %{id: index, images: images, index: index}
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
