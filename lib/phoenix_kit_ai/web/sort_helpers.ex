defmodule PhoenixKitAI.Web.SortHelpers do
  @moduledoc """
  Shared URL-param parsing for the AI admin LVs (`endpoints.ex`,
  `prompts.ex`, plus the usage tab inside endpoints).

  Each LV passes its allowed sort-field whitelist + the sort default
  + (optionally) the direction default; the helper validates and
  falls back to those defaults on malformed input.
  """

  @doc """
  Parses `sort` / `dir` / `page` URL params into a canonical
  `{sort_by, sort_dir, page}` tuple. Sort field is cast via
  `String.to_existing_atom/1` after a whitelist check, so an
  unrecognised value can't allocate a new atom.

  ## Options

  - `:valid_fields` — list of binary field names allowed by the caller
    (e.g. `~w(name inserted_at sort_order)`). Required.
  - `:default_sort` — atom returned when `sort` is absent or invalid.
    Required.
  - `:default_dir` — direction returned when `dir` is absent or
    unrecognised. Default `:asc`.
  """
  @spec parse_sort_params(map(), keyword()) :: {atom(), :asc | :desc, pos_integer()}
  def parse_sort_params(params, opts) when is_map(params) and is_list(opts) do
    valid_fields = Keyword.fetch!(opts, :valid_fields)
    default_sort = Keyword.fetch!(opts, :default_sort)
    default_dir = Keyword.get(opts, :default_dir, :asc)

    {
      parse_sort_field(params["sort"], valid_fields, default_sort),
      parse_sort_dir(params["dir"], default_dir),
      parse_page(params["page"])
    }
  end

  @doc """
  Returns `field` as an atom if it appears in `valid_fields`, otherwise
  `default`. Non-binary inputs return the default directly.
  """
  @spec parse_sort_field(any(), [String.t()], atom()) :: atom()
  def parse_sort_field(field, valid_fields, default) when is_binary(field) do
    if field in valid_fields, do: String.to_existing_atom(field), else: default
  end

  def parse_sort_field(_, _valid_fields, default), do: default

  @doc """
  Coerces `dir` to `:asc` / `:desc`. Unknown input returns `default`.
  """
  @spec parse_sort_dir(any(), :asc | :desc) :: :asc | :desc
  def parse_sort_dir("asc", _default), do: :asc
  def parse_sort_dir("desc", _default), do: :desc
  def parse_sort_dir(_, default), do: default

  @doc """
  Coerces `page` to a positive integer (default `1` for nil / empty /
  invalid input).
  """
  @spec parse_page(any()) :: pos_integer()
  def parse_page(nil), do: 1
  def parse_page(""), do: 1

  def parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  def parse_page(_), do: 1
end
