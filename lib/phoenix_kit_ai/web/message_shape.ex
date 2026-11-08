defmodule PhoenixKitAI.Web.MessageShape do
  @moduledoc """
  Describes a process message or failure by its shape, for log lines.

  A LiveView mailbox receives messages this module does not own (PubSub
  from other modules, late task replies), and any of them may carry a
  credential or user content. The catch-alls therefore log what kind of
  message arrived — its tag and arity, or its struct name — and never the
  message itself. Failure logs use the same description because exception
  messages, stack arguments and transport errors can carry those payloads too.
  """

  @doc """
  Returns a loggable description of `msg` that contains none of its payload.

  ## Examples

      iex> PhoenixKitAI.Web.MessageShape.describe(:tick)
      ":tick"

      iex> PhoenixKitAI.Web.MessageShape.describe({:saved, "secret", %{}})
      "{:saved, …}/3"

      iex> PhoenixKitAI.Web.MessageShape.describe(%URI{host: "secret"})
      "%URI{}"

      iex> PhoenixKitAI.Web.MessageShape.describe("secret")
      "binary"
  """
  @spec describe(term()) :: String.t()
  def describe(msg) when is_atom(msg), do: inspect(msg)
  def describe(%module{}), do: "%#{inspect(module)}{}"

  def describe(msg) when is_tuple(msg) and tuple_size(msg) > 0 do
    case elem(msg, 0) do
      tag when is_atom(tag) -> "{#{inspect(tag)}, …}/#{tuple_size(msg)}"
      _ -> "tuple/#{tuple_size(msg)}"
    end
  end

  def describe(msg) when is_tuple(msg), do: "tuple/0"
  def describe(msg) when is_binary(msg), do: "binary"
  def describe(msg) when is_map(msg), do: "map"
  def describe(msg) when is_list(msg), do: "list"
  def describe(_msg), do: "term"

  @doc """
  Describes the reason a task exited with (`{:exit, reason}` in
  `handle_async/3`) without its payload: for a crash the exception's module
  and the function and line it was raised in — never the exception's
  message or the function's arguments, which can carry what the task was
  given — else `describe/1` of the reason.

  ## Examples

      iex> PhoenixKitAI.Web.MessageShape.describe_exit(
      ...>   {%RuntimeError{message: "secret"}, [{MyApp.Voice, :run, ["secret"], [file: ~c"lib/voice.ex", line: 7]}]}
      ...> )
      "RuntimeError in MyApp.Voice.run/1 (lib/voice.ex:7)"

      iex> PhoenixKitAI.Web.MessageShape.describe_exit({:timeout, {GenServer, :call, ["secret"]}})
      "{:timeout, …}/2"
  """
  @spec describe_exit(term()) :: String.t()
  def describe_exit({%{__exception__: true, __struct__: module}, stacktrace})
      when is_list(stacktrace),
      do: inspect(module) <> where(stacktrace)

  def describe_exit({reason, [{module, function, _, _} | _]})
      when is_atom(module) and is_atom(function),
      do: describe(reason)

  def describe_exit(reason), do: describe(reason)

  defp where([{module, function, arity_or_args, location} | _])
       when is_atom(module) and is_atom(function) and is_list(location) do
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
    " in #{inspect(module)}.#{function}/#{arity}" <> line(location[:file], location[:line])
  end

  defp where(_stacktrace), do: ""

  defp line(file, line) when is_list(file) and is_integer(line), do: " (#{file}:#{line})"
  defp line(_file, _line), do: ""
end
