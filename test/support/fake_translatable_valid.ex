defmodule PhoenixKitAI.Test.FakeTranslatableValid do
  @moduledoc """
  Sibling of `PhoenixKitAI.Test.FakeTranslatable` whose `source_fields/2`
  returns a real, valid `%{String => String}` map — so `TranslateWorker`
  proceeds past `safe_source_fields/1` and into an actual
  `PhoenixKitAI.Translation.translate_fields/6` call.

  Pairs with a stubbed `Req.Test` transport (see
  `PhoenixKitAI.TranslateWorkerFailureLoggingTest`) to reach `fail/3`'s
  `retry?` path deterministically, with no real network call — the only
  way to reach the retry-exhausted `cond` clause is through a genuinely
  retryable `{:ai_error, _}` reason, which only the AI call produces.
  """

  @behaviour PhoenixKitAI.Translatable

  @resource_type "ai_test_fake_resource_valid"

  @doc "The resource_type this fake adapter is registered under."
  def resource_type, do: @resource_type

  @doc false
  def ai_translatables, do: [{@resource_type, __MODULE__}]

  @impl true
  def fetch(_type, uuid), do: {:ok, %{uuid: uuid}}

  @impl true
  def source_fields(_resource, _source_lang), do: %{"name" => "Hello world"}

  @impl true
  def put_translation(resource, _target_lang, _fields, _opts), do: {:ok, resource}
end
