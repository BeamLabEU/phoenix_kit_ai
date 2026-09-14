defmodule PhoenixKitAI.Test.FakeTranslatable do
  @moduledoc """
  Minimal `PhoenixKitAI.Translatable` adapter for exercising
  `PhoenixKitAI.TranslateWorker`'s deterministic-failure paths without a
  live AI endpoint or a real consumer module.

  Registered/unregistered per-test via `PhoenixKit.ModuleRegistry`
  (`register/1` + `unregister/1`) — see
  `PhoenixKitAI.TranslateWorkerFailureLoggingTest`. `source_fields/2`
  deliberately returns a non-string value so `TranslateWorker` hits its
  `safe_source_fields/1` → `validate_source_map/1` → `fail/3` path with
  zero network calls, the same `fail/3` clause the reported
  `{:parse_error, :no_markers}` bug goes through.
  """

  @behaviour PhoenixKitAI.Translatable

  @resource_type "ai_test_fake_resource"

  @doc "The resource_type this fake adapter is registered under."
  def resource_type, do: @resource_type

  @doc false
  def ai_translatables, do: [{@resource_type, __MODULE__}]

  @impl true
  def fetch(_type, uuid), do: {:ok, %{uuid: uuid}}

  @impl true
  def source_fields(_resource, _source_lang), do: %{"name" => 123}

  @impl true
  def put_translation(resource, _target_lang, _fields, _opts), do: {:ok, resource}
end
