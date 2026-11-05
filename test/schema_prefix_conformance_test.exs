defmodule PhoenixKitAi.SchemaPrefixConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support: every
  table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries
  target the schema core's migrations installed into. A schema missing
  it silently falls back to `search_path` resolution — invisible on
  public installs, broken on prefixed ones. A query that bypasses the
  schema (a string source, or Oban's own table) falls back the same way.
  """

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        content = File.read!(path)

        String.contains?(content, ~s[schema "phoenix_kit]) and
          not String.contains?(content, "use PhoenixKit.SchemaPrefix")
      end)

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end

  test "no query names a kit table as a string, which would skip the prefix" do
    offenders = Enum.filter(lib_files(), &(File.read!(&1) =~ ~r/\bin "phoenix_kit_/))

    assert offenders == [],
           "queries with a string source carry no schema prefix: use the table's " <>
             "schema (core's `PhoenixKit.Settings.Setting` for the settings): " <>
             inspect(offenders)
  end

  test "every query of Oban's table takes the running instance's prefix" do
    offenders =
      lib_files()
      |> Enum.reject(&String.ends_with?(&1, "/oban_query.ex"))
      |> Enum.filter(fn path ->
        content = File.read!(path)

        content =~ ~r/\bin (Oban\.Job|"oban_jobs")/ and
          not String.contains?(content, "ObanQuery.scoped")
      end)

    assert offenders == [],
           "`Oban.Job` and \"oban_jobs\" carry no schema prefix: pipe the query " <>
             "through `PhoenixKitAI.ObanQuery.scoped/1`: #{inspect(offenders)}"
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")
end
