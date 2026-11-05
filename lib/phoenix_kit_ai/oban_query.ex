defmodule PhoenixKitAI.ObanQuery do
  @moduledoc """
  Reads Oban's table in the schema the host's Oban runs in.

  An install with a named schema (`mix phoenix_kit.install --prefix`) keeps
  `oban_jobs` in that schema and writes `prefix:` into the host's Oban config.
  `Oban.Job` and the `"oban_jobs"` source carry no prefix of their own, so a query
  written without this one goes to the search path and finds another table or
  none, and most of the module's reads of the table fail open: the translation
  dedupe then stops working with no error at all.

  Every query of Oban's table goes through `scoped/1`
  (`test/schema_prefix_conformance_test.exs` checks it).
  """

  import Ecto.Query, only: [put_query_prefix: 2]

  @doc "`queryable` in the schema of the running Oban instance."
  @spec scoped(Ecto.Queryable.t()) :: Ecto.Query.t()
  def scoped(queryable), do: put_query_prefix(queryable, prefix())

  @doc """
  The schema of the running Oban instance. `nil` means the search path decides:
  an instance configured with `prefix: false`, or none running.
  """
  @spec prefix() :: String.t() | nil
  def prefix do
    case Oban.config(Oban).prefix do
      prefix when is_binary(prefix) -> prefix
      _search_path -> nil
    end
  rescue
    # `Oban.config/1` raises with no instance running, and the registry behind
    # it is missing while `:oban` is not started.
    _not_running in [RuntimeError, ArgumentError] -> nil
  end
end
