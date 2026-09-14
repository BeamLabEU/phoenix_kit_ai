defmodule PhoenixKitAI.Test.FakeTranslatablePersistFailure do
  @moduledoc """
  Sibling of `PhoenixKitAI.Test.FakeTranslatableValid` whose
  `put_translation/4` returns a shape `PhoenixKitAI.TranslateWorker`'s
  `safe_put_translation/2` treats as malformed (any non-`{:ok, _}` /
  `{:error, _}` return), so `persist/2` reaches `fail(ctx, {:persist_error,
  {:bad_put_translation, other}}, ...)` deterministically — the real,
  wrapped shape `classify_reason/1` must resolve to `{"persist_error",
  "bad_put_translation"}`.
  """

  @behaviour PhoenixKitAI.Translatable

  @resource_type "ai_test_fake_resource_persist_failure"

  @doc "The resource_type this fake adapter is registered under."
  def resource_type, do: @resource_type

  @doc false
  def ai_translatables, do: [{@resource_type, __MODULE__}]

  @impl true
  def fetch(_type, uuid), do: {:ok, %{uuid: uuid}}

  @impl true
  def source_fields(_resource, _source_lang), do: %{"name" => "Hello world"}

  @impl true
  def put_translation(_resource, _target_lang, _fields, _opts), do: :not_a_tuple
end
