defmodule PhoenixKitAI.EmbeddingConventions do
  @moduledoc """
  How an embedding model wants a search **query** and a stored **document**
  told apart, so `PhoenixKitAI.embed/3`'s `role: :query | :document` can do
  the right thing per model.

  Retrieval models are trained with a convention: a request field
  (`input_type`), a text prefix, or nothing at all. Embedding a query the way
  the model embeds documents (or leaving out its instruction) still returns a
  vector, so nothing fails — search just gets quietly worse. Measured on
  OpenRouter (2026-11, image-search queries in five languages, precision of
  the top 24): Qwen3-Embedding without its query instruction dropped from
  0.70 to 0.52, gemini-embedding-2 without its prefixes from 0.82 to 0.55,
  Cohere without `input_type` from 0.72 to 0.62.

  ## The table

  | Family (model id contains) | query | document |
  |---|---|---|
  | `gemini-embedding-2`, `embeddinggemma` | prefix `task: search result \\| query: ` | prefix `title: none \\| text: ` |
  | `gemini-embedding` (001) | `input_type: "search_query"` | `input_type: "search_document"` |
  | Cohere (`cohere/`, `embed-english`, `embed-multilingual`, `embed-v4`, `embed-5`) | `input_type: "search_query"` | `input_type: "search_document"` |
  | Voyage (`voyage`) | `input_type: "query"` | `input_type: "document"` |
  | Nvidia (`nemotron` + `embed`, `nv-embed`) | `input_type: "query"` | `input_type: "passage"` |
  | Qwen3-Embedding (`qwen3-embedding`) | `Instruct: <instruction>\\nQuery: <text>` | — |
  | e5 instruct (`e5` + `instruct`) | `Instruct: <instruction>\\nQuery: <text>` | — |
  | e5 (`e5-`) | prefix `query: ` | prefix `passage: ` |
  | anything else (OpenAI, Mistral, BGE, pplx, Titan, …) | — | — |

  A table `input_type` is sent to OpenRouter endpoints only: that is where
  the values were checked, and some providers refuse a field they do not
  know (OpenAI's own API answers 400). Voyage and Nvidia also answer 400 to
  a value they do not know, so an unknown family gets no `input_type` at
  all. Prefixes are part of the model, not of the route, and apply on every
  provider.

  `<instruction>` is `"#{"Given a web search query, retrieve relevant passages that answer the query"}"`
  unless the call's `instruction:` or the endpoint's override names another
  (Qwen's own default; describe the task — "Given an image search query,
  retrieve descriptions of images that match the query").

  ## Overriding per endpoint

  `provider_settings["embedding"]` on the endpoint replaces any entry of the
  table for that endpoint (no migration — it is the existing settings map):

      %{
        "query_template" => "Instruct: {instruction}\\nQuery: {text}",
        "document_template" => "{text}",
        "input_type" => %{"query" => "search_query", "document" => "search_document"},
        "instruction" => "Given an image search query, retrieve descriptions of images"
      }

  A template holds `{text}` (and optionally `{instruction}`); one without
  `{text}` is a prefix. `""` (or `nil`) means "nothing" — a way to switch a
  table entry off. An `input_type` set here is sent on any provider.

  ## Other model facts

  `max_inputs/1` is the most inputs one request takes: Cohere 96, OpenAI 2 048, Voyage 1 000, Gemini 100, else 100.
  `max_batch_tokens/1` is a request's token budget where the provider has
  one (OpenAI 300 000; Voyage 120 000, the strictest of its models), else nil.
  `dimensions?/1` is false for `mistral-embed`, which answers 422 to a
  `dimensions` field.
  """

  @default_instruction "Given a web search query, retrieve relevant passages that answer the query"
  @instruct_template "Instruct: {instruction}\nQuery: {text}"

  # First match wins: gemini-embedding-2 before gemini-embedding, e5
  # instruct before plain e5.
  @families [
    gemini_2: &__MODULE__.gemini_2?/1,
    gemini: &__MODULE__.gemini?/1,
    cohere: &__MODULE__.cohere?/1,
    voyage: &__MODULE__.voyage?/1,
    nvidia: &__MODULE__.nvidia?/1,
    qwen3: &__MODULE__.qwen3?/1,
    e5_instruct: &__MODULE__.e5_instruct?/1,
    e5: &__MODULE__.e5?/1,
    mistral: &__MODULE__.mistral?/1,
    openai: &__MODULE__.openai?/1
  ]

  @type role :: :query | :document
  @type family ::
          :gemini_2
          | :gemini
          | :cohere
          | :voyage
          | :nvidia
          | :qwen3
          | :e5_instruct
          | :e5
          | :mistral
          | :openai
          | nil

  @typedoc """
  What a role resolves to on one endpoint: the `input_type` to send (or nil),
  the template applied to every text input (or nil), and where the
  convention came from.
  """
  @type resolved :: %{
          role: role() | nil,
          input_type: String.t() | nil,
          template: String.t() | nil,
          instruction: String.t() | nil,
          family: family()
        }

  @doc "The default task text for instruction-style query templates."
  @spec default_instruction() :: String.t()
  def default_instruction, do: @default_instruction

  @doc """
  The model family of an embedding model id (`"qwen/qwen3-embedding-8b"`,
  `"gemini-embedding-001"`), or nil when the module knows no convention for it.
  """
  @spec family(String.t() | nil) :: family()
  def family(model) when is_binary(model) do
    id = String.downcase(model)

    Enum.find_value(@families, fn {family, matches?} -> if matches?.(id), do: family end)
  end

  def family(_model), do: nil

  @doc false
  def gemini_2?(id),
    do: String.contains?(id, "gemini-embedding-2") or String.contains?(id, "embeddinggemma")

  @doc false
  def gemini?(id), do: String.contains?(id, "gemini-embedding")

  @doc false
  def cohere?(id),
    do:
      String.starts_with?(id, "cohere/") or
        Regex.match?(~r/(^|\/)embed-(english|multilingual|v\d|\d)/, id)

  @doc false
  def voyage?(id), do: String.contains?(id, "voyage")

  @doc false
  def nvidia?(id),
    do:
      (String.contains?(id, "nemotron") and String.contains?(id, "embed")) or
        String.contains?(id, "nv-embed")

  @doc false
  def qwen3?(id), do: String.contains?(id, "qwen3-embedding")

  @doc false
  def e5_instruct?(id), do: e5?(id) and String.contains?(id, "instruct")

  @doc false
  def e5?(id), do: Regex.match?(~r/(^|\/|-)e5-/, id)

  @doc false
  def mistral?(id), do: String.contains?(id, "mistral-embed")

  @doc false
  def openai?(id),
    do: String.contains?(id, "text-embedding-3") or String.contains?(id, "text-embedding-ada")

  # The table: per family, the input_type per role and the template per role.
  defp table(:gemini_2),
    do: %{
      input_type: %{},
      template: %{
        query: "task: search result | query: {text}",
        document: "title: none | text: {text}"
      }
    }

  defp table(:gemini),
    do: %{input_type: %{query: "search_query", document: "search_document"}, template: %{}}

  defp table(:cohere),
    do: %{input_type: %{query: "search_query", document: "search_document"}, template: %{}}

  defp table(:voyage), do: %{input_type: %{query: "query", document: "document"}, template: %{}}
  defp table(:nvidia), do: %{input_type: %{query: "query", document: "passage"}, template: %{}}

  defp table(family) when family in [:qwen3, :e5_instruct],
    do: %{input_type: %{}, template: %{query: @instruct_template}}

  defp table(:e5),
    do: %{input_type: %{}, template: %{query: "query: {text}", document: "passage: {text}"}}

  defp table(_family), do: %{input_type: %{}, template: %{}}

  @doc """
  What `role` means for `endpoint` (its `model` — a call's `model:` already
  applied — and `provider_settings["embedding"]`), with the call's own
  `input_type:` and `instruction:` winning.

  Returns `{:ok, resolved}`, or `{:error, :invalid_embedding_role}` for a
  role that is neither `:query` nor `:document` (strings accepted).
  Never raises: a malformed override is ignored.
  """
  @spec resolve(map(), keyword()) :: {:ok, resolved()} | {:error, :invalid_embedding_role}
  def resolve(endpoint, opts) do
    with {:ok, role} <- role(Keyword.get(opts, :role)) do
      model = Map.get(endpoint, :model)
      family = family(model)
      override = override(endpoint)
      entry = table(family)

      instruction =
        string_or_nil(Keyword.get(opts, :instruction)) ||
          string_or_nil(override["instruction"]) || @default_instruction

      input_type =
        case string_or_nil(Keyword.get(opts, :input_type)) do
          nil -> role_input_type(role, entry, override, endpoint)
          explicit -> explicit
        end

      template = role_template(role, entry, override)

      {:ok,
       %{
         role: role,
         input_type: input_type,
         template: template,
         instruction:
           if(template && String.contains?(template, "{instruction}"), do: instruction),
         family: family
       }}
    end
  end

  defp role(nil), do: {:ok, nil}
  defp role(role) when role in [:query, :document], do: {:ok, role}
  defp role("query"), do: {:ok, :query}
  defp role("document"), do: {:ok, :document}
  defp role(_other), do: {:error, :invalid_embedding_role}

  defp role_input_type(nil, _entry, _override, _endpoint), do: nil

  defp role_input_type(role, entry, override, endpoint) do
    case override["input_type"] do
      %{} = by_role when is_map_key(by_role, "query") or is_map_key(by_role, "document") ->
        string_or_nil(by_role[Atom.to_string(role)])

      _ ->
        if PhoenixKitAI.Endpoint.openrouter?(endpoint), do: entry.input_type[role]
    end
  end

  defp role_template(nil, _entry, _override), do: nil

  defp role_template(role, entry, override) do
    key = "#{role}_template"

    if Map.has_key?(override, key),
      do: string_or_nil(override[key]),
      else: entry.template[role]
  end

  defp override(endpoint) do
    case Map.get(endpoint, :provider_settings) do
      %{"embedding" => %{} = embedding} -> embedding
      _ -> %{}
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  @doc """
  `text` through `template`: `{text}` and `{instruction}` replaced, or the
  template prepended when it has no `{text}`. A nil template leaves the text
  as it is.
  """
  @spec apply_template(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def apply_template(text, nil, _instruction), do: text

  def apply_template(text, template, instruction) do
    template = String.replace(template, "{instruction}", instruction || @default_instruction)

    if String.contains?(template, "{text}"),
      do: String.replace(template, "{text}", text),
      else: template <> text
  end

  @doc """
  The most inputs one embeddings request takes for `model` (Cohere 96,
  OpenAI 2 048, Voyage 1 000, Gemini 100; 100 for a model the table does
  not know).
  """
  @spec max_inputs(String.t() | nil) :: pos_integer()
  def max_inputs(model) do
    case family(model) do
      :cohere -> 96
      :openai -> 2_048
      :voyage -> 1_000
      _ -> 100
    end
  end

  @doc """
  A request's token budget for `model`, where the provider has one
  (OpenAI 300 000 tokens per request; Voyage 120 000, its strictest model's),
  else nil.
  """
  @spec max_batch_tokens(String.t() | nil) :: pos_integer() | nil
  def max_batch_tokens(model) do
    case family(model) do
      :openai -> 300_000
      :voyage -> 120_000
      _ -> nil
    end
  end

  @doc """
  Whether `model` takes a `dimensions` field. `mistral-embed` answers 422 to
  it, so `embed/3` leaves it out there (with a warning).
  """
  @spec dimensions?(String.t() | nil) :: boolean()
  def dimensions?(model), do: family(model) != :mistral

  @doc """
  L2-normalises a vector (a list of numbers); a zero vector or anything that
  is not a list of numbers is returned as it is.
  """
  @spec normalize([number()]) :: [float()]
  def normalize(vector) when is_list(vector) do
    if Enum.all?(vector, &is_number/1) do
      norm = vector |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt()
      if norm > 0.0, do: Enum.map(vector, &(&1 / norm)), else: vector
    else
      vector
    end
  end

  def normalize(other), do: other
end
