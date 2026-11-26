defmodule PhoenixKitAI.ContentHashes do
  @moduledoc """
  "Has this content changed since last time?" — a stored hash per source, so a
  crawler (or any repeated ingest) skips the pages whose text is what it was.

  `PhoenixKitAI.RequestCache` keys on the *request*: a re-rendered prompt, a
  new model or an edited endpoint is a miss, and the cache is ETS on one node,
  gone on restart. A crawler wants the opposite: a key on the *content* the
  model would see — the extracted text, not the HTML around it, which changes
  with every ad and timestamp — kept across restarts. That is this table:
  one row per `(namespace, source_key)` holding the hash of what was last
  recorded for it.

      text = PhoenixKitAI.Fetch.fetch(url) |> ... # the clean text
      case PhoenixKitAI.ContentHashes.check("saali:pages", url, text) do
        {:unchanged, _hash} -> :skip
        {status, hash} when status in [:new, :changed] ->
          with {:ok, _} <- process(text),
               do: PhoenixKitAI.ContentHashes.record("saali:pages", url, {:hash, hash})
      end

  `check/3` only reads; `record/4` writes, so a page whose processing failed
  is not marked as done. `changed?/3` is the boolean of `check/3`.

  ## The hash

  `hash/2` is `"sha256:" <> hex` over the content after normalisation:
  Unicode NFC, every run of whitespace one space, trimmed — so a re-crawl that
  only re-indents the page or swaps `\\r\\n` for `\\n` is unchanged.
  `normalize: false` hashes the bytes as given. A map of fields
  (`%{"title" => …, "body" => …}`) is hashed field by field in key order, so
  the order a map happens to list them in never matters. A caller that
  already holds a hash passes `{:hash, hash}` anywhere content is taken.

  ## Keys

  `namespace` is the caller's (`"saali:pages"`, `"catalogue:import"`;
  at most 255 bytes); `source_key` names the source in it (a URL, an id;
  at most 2 048 bytes — a URL in its percent-encoded form fits). Bytes, not
  characters: the pair is one entry of a unique B-tree index, which takes
  at most about 2 700 bytes. `"ai."` namespaces are this module's own
  (`PhoenixKitAI.Translations` pins translations under `"ai.translation:…"`).
  Rows are kept until deleted (`delete/2`, `delete_namespace/1`); journal
  retention does not touch them. `unchecked_since/3` lists the sources a crawl
  did not see again — pages that went away.
  """

  import Ecto.Query

  alias PhoenixKitAI.ContentHash

  @namespace_max 255
  @key_max 2048

  @type content :: String.t() | %{optional(term()) => term()} | {:hash, String.t()}
  @type status :: :new | :changed | :unchanged

  @doc """
  The hash of `content` (see the moduledoc). Options: `normalize:` (default
  `true`).
  """
  @spec hash(content(), keyword()) :: String.t()
  def hash(content, opts \\ [])

  def hash({:hash, hash}, _opts) when is_binary(hash), do: hash

  def hash(text, opts) when is_binary(text) do
    "sha256:" <> hex(:crypto.hash(:sha256, normalize(text, opts)))
  end

  def hash(%{} = fields, opts) do
    material =
      fields
      |> Enum.map(fn {key, value} -> {to_string(key), value_text(value, opts)} end)
      |> Enum.sort()
      |> :erlang.term_to_binary([:deterministic])

    "sha256:" <> hex(:crypto.hash(:sha256, material))
  end

  @doc """
  Whether `content` differs from what was last recorded for the source:
  `{:new, hash}` when nothing was, `{:changed, hash}` or `{:unchanged, hash}`.
  Reads only. `{:error, reason}` for an invalid namespace or key.
  """
  @spec check(String.t(), String.t(), content(), keyword()) ::
          {status(), String.t()} | {:error, term()}
  def check(namespace, source_key, content, opts \\ []) do
    with :ok <- validate(namespace, source_key) do
      hash = hash(content, opts)

      case get(namespace, source_key) do
        nil -> {:new, hash}
        %ContentHash{content_hash: ^hash} -> {:unchanged, hash}
        %ContentHash{} -> {:changed, hash}
      end
    end
  end

  @doc "True unless `content` is what was last recorded for the source (a new source is changed)."
  @spec changed?(String.t(), String.t(), content(), keyword()) :: boolean()
  def changed?(namespace, source_key, content, opts \\ []) do
    match?(
      {status, _} when status in [:new, :changed],
      check(namespace, source_key, content, opts)
    )
  end

  @doc """
  Records `content` as what the source holds now: one upsert. `changed_at`
  moves only when the hash differs from the stored one; `checked_at` always.
  Options: `normalize:`, `metadata:` (a map stored with the row, replacing the
  previous one; nothing content-like belongs there — keep it to ids and
  counts), `now:` (a `DateTime`, for tests and backfills).

  Returns `{:ok, status, row}` with the status `check/3` would have given just
  before, or `{:error, reason}`.
  """
  @spec record(String.t(), String.t(), content(), keyword()) ::
          {:ok, status(), ContentHash.t()} | {:error, term()}
  def record(namespace, source_key, content, opts \\ []) do
    with :ok <- validate(namespace, source_key) do
      hash = hash(content, opts)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      previous = get(namespace, source_key)

      status =
        case previous do
          nil -> :new
          %ContentHash{content_hash: ^hash} -> :unchanged
          _ -> :changed
        end

      row = %ContentHash{
        namespace: namespace,
        source_key: source_key,
        content_hash: hash,
        content_bytes: bytes(content),
        metadata: Keyword.get(opts, :metadata) || %{},
        changed_at: now,
        checked_at: now,
        inserted_at: now,
        updated_at: now
      }

      # `changed_at` keeps the stored moment when the hash is the same, also
      # under a concurrent writer: the comparison is the database's.
      on_conflict =
        from(c in ContentHash,
          update: [
            set: [
              content_hash: fragment("EXCLUDED.content_hash"),
              content_bytes: fragment("EXCLUDED.content_bytes"),
              metadata: fragment("EXCLUDED.metadata"),
              checked_at: fragment("EXCLUDED.checked_at"),
              updated_at: fragment("EXCLUDED.updated_at"),
              changed_at:
                fragment(
                  "CASE WHEN ? = EXCLUDED.content_hash THEN ? ELSE EXCLUDED.changed_at END",
                  c.content_hash,
                  c.changed_at
                )
            ]
          ]
        )

      case repo().insert(row,
             on_conflict: on_conflict,
             conflict_target: [:namespace, :source_key],
             returning: true
           ) do
        {:ok, row} -> {:ok, status, row}
        {:error, _} = error -> error
      end
    end
  end

  @doc "The stored row of a source, or nil."
  @spec get(String.t(), String.t()) :: ContentHash.t() | nil
  def get(namespace, source_key) when is_binary(namespace) and is_binary(source_key),
    do: repo().get_by(ContentHash, namespace: namespace, source_key: source_key)

  def get(_namespace, _source_key), do: nil

  @doc "The stored hash of a source, or nil."
  @spec stored_hash(String.t(), String.t()) :: String.t() | nil
  def stored_hash(namespace, source_key) do
    case get(namespace, source_key) do
      %ContentHash{content_hash: hash} -> hash
      nil -> nil
    end
  end

  @doc """
  The sources of `namespace` not recorded since `since` (a `DateTime`): what
  a crawl that started at `since` did not see again. Options: `limit:`
  (default 1 000).
  """
  @spec unchecked_since(String.t(), DateTime.t(), keyword()) :: [ContentHash.t()]
  def unchecked_since(namespace, %DateTime{} = since, opts \\ []) when is_binary(namespace) do
    from(c in ContentHash,
      where: c.namespace == ^namespace and c.checked_at < ^since,
      order_by: [asc: c.checked_at, asc: c.source_key],
      limit: ^Keyword.get(opts, :limit, 1_000)
    )
    |> repo().all()
  end

  @doc "Forgets one source: the next `check/3` reads it as new."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(namespace, source_key) do
    from(c in ContentHash, where: c.namespace == ^namespace and c.source_key == ^source_key)
    |> repo().delete_all()

    :ok
  end

  @doc "Forgets every source of a namespace; returns how many."
  @spec delete_namespace(String.t()) :: non_neg_integer()
  def delete_namespace(namespace) when is_binary(namespace) do
    {count, _} = from(c in ContentHash, where: c.namespace == ^namespace) |> repo().delete_all()
    count
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp validate(namespace, source_key) do
    cond do
      not is_binary(namespace) or String.trim(namespace) == "" -> {:error, :invalid_namespace}
      byte_size(namespace) > @namespace_max -> {:error, :invalid_namespace}
      not is_binary(source_key) or source_key == "" -> {:error, :invalid_source_key}
      byte_size(source_key) > @key_max -> {:error, :invalid_source_key}
      true -> :ok
    end
  end

  defp normalize(text, opts) do
    if Keyword.get(opts, :normalize, true) do
      text
      |> String.normalize(:nfc)
      |> String.split()
      |> Enum.join(" ")
    else
      text
    end
  end

  defp value_text(value, opts) when is_binary(value), do: normalize(value, opts)
  defp value_text(nil, _opts), do: nil
  defp value_text(value, opts) when is_map(value), do: hash(value, opts)
  defp value_text(value, _opts), do: inspect(value)

  defp bytes(text) when is_binary(text), do: byte_size(text)

  defp bytes(%{} = fields) do
    Enum.reduce(fields, 0, fn
      {_key, value}, acc when is_binary(value) -> acc + byte_size(value)
      _, acc -> acc
    end)
  end

  defp bytes(_content), do: nil

  defp hex(digest), do: Base.encode16(digest, case: :lower)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
