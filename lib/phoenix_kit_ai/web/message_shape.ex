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
end
