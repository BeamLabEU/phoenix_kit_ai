defmodule PhoenixKitAI.TaskSpec do
  @moduledoc """
  The declaration of an AI task: a named use of AI that a module's code
  makes, returned by the module's `ai_tasks/0` callback and found by
  `PhoenixKitAI.Tasks`.

      def ai_tasks do
        [
          %PhoenixKitAI.TaskSpec{
            key: "warehouse.inventory_photo",
            label: gettext_noop("Inventory by photo"),
            gettext_backend: MyModule.Gettext,
            purpose: gettext_noop("Count the stock items visible in shelf photos."),
            needs: [:vision, :json_schema],
            endpoints: {MyModule.Settings, :inventory_endpoint_uuids, []}
          }
        ]
      end

  The key is a string prefixed with the module's key. `needs` says what the
  model has to be able to do: `:vision` (images in), `:tools`,
  `:json_schema` (a strict JSON schema) — hard requirements a call is
  refused for — and `:json` (any JSON; soft, only noted). `endpoints` is an
  `{module, function, args}` returning the endpoints the task uses now (uuids
  or `%PhoenixKitAI.Endpoint{}`s, a single one, `{:ok, uuid}` or `nil`).

  `default_limits` are the task's limits when an admin has set none
  (`%{task: %{unit => %{period => amount}}, user: …}`, units `:money` in
  micro-dollars, `:requests`, `:tokens`, periods `:day`, `:month` — see
  `PhoenixKitAI.TaskLimits`). `watchers` is an `{module, function, args}`
  called with the user uuid (or nil) appended, returning the uuids of more
  people to tell about the task's limits (`PhoenixKitAI.GuardEvents`); the
  user is never told as a watcher.

  `self_flag`, `private`, `sources`, `max_calls_per_hour`,
  `max_tokens_per_call`, `auto_block_threshold`, `block_group` and
  `content` are accepted and kept for the guard's later parts (off-purpose
  marks, blocks); nothing reads them yet. `typical_tokens` (`{input,
  output}` of a typical call) is read by `PhoenixKitAI.Recommendations` to
  estimate the price of a call.

  `module` and `enabled` are filled in by `PhoenixKitAI.Tasks`: the module
  that declared the task, and whether that module is switched on.
  """

  @type need :: :vision | :tools | :json_schema | :json
  @type mfa_ref :: {module(), atom(), list()}

  @type t :: %__MODULE__{
          key: String.t(),
          label: String.t() | nil,
          gettext_backend: module() | nil,
          purpose: String.t() | nil,
          needs: [need()],
          self_flag: boolean(),
          private: boolean(),
          sources: [String.t()] | nil,
          max_calls_per_hour: pos_integer() | nil,
          max_tokens_per_call: pos_integer() | nil,
          auto_block_threshold: pos_integer() | nil,
          block_group: String.t() | nil,
          endpoints: mfa_ref() | nil,
          watchers: mfa_ref() | nil,
          content: mfa_ref() | nil,
          default_limits: map(),
          typical_tokens: {non_neg_integer(), non_neg_integer()} | nil,
          module: module() | nil,
          enabled: boolean()
        }

  @enforce_keys [:key]
  defstruct key: nil,
            label: nil,
            gettext_backend: nil,
            purpose: nil,
            needs: [],
            self_flag: false,
            private: false,
            sources: nil,
            max_calls_per_hour: nil,
            max_tokens_per_call: nil,
            auto_block_threshold: nil,
            block_group: nil,
            endpoints: nil,
            watchers: nil,
            content: nil,
            default_limits: %{},
            typical_tokens: nil,
            module: nil,
            enabled: true

  @needs [:vision, :tools, :json_schema, :json]
  @hard_needs [:vision, :tools, :json_schema]

  @doc "Every requirement a task or a call can have."
  @spec needs() :: [need()]
  def needs, do: @needs

  @doc "The requirements a call is refused for when the model lacks them."
  @spec hard_needs() :: [need()]
  def hard_needs, do: @hard_needs

  @doc """
  The task's label in the current locale, through its own gettext backend
  when it names one; the key when it has no label.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{label: label, key: key}) when label in [nil, ""], do: key

  def label(%__MODULE__{label: label, gettext_backend: backend})
      when is_atom(backend) and not is_nil(backend) do
    Gettext.dgettext(backend, "default", label)
  rescue
    _ -> label
  end

  def label(%__MODULE__{label: label}), do: label

  @doc """
  The task's purpose for display, translated through the declaring module's
  `gettext_backend` when one is set (declare it with `gettext_noop/1`). The
  untranslated text is what prompts and classifiers get, so their wording
  stays the same in every locale.
  """
  @spec purpose(t()) :: String.t() | nil
  def purpose(%__MODULE__{purpose: purpose}) when purpose in [nil, ""], do: nil

  def purpose(%__MODULE__{purpose: purpose, gettext_backend: backend})
      when is_atom(backend) and not is_nil(backend) do
    Gettext.dgettext(backend, "default", purpose)
  rescue
    _ -> purpose
  end

  def purpose(%__MODULE__{purpose: purpose}), do: purpose
end
