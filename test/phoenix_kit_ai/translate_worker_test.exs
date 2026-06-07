defmodule PhoenixKitAI.TranslateWorkerTest do
  @moduledoc """
  Unit coverage for `PhoenixKitAI.TranslateWorker` that doesn't need
  a live `PhoenixKitAI` plugin:

    * `retryable?/1` — transient AI errors retry, deterministic ones don't.
    * `perform/1` setup-failure paths (bad args / unknown adapter) discard
      cleanly and broadcast a normalised `:translation_failed` — all BEFORE
      any AI call.

  The success path (the real `ask_with_prompt/4` round-trip + persist) needs a
  seeded endpoint + prompt + a registered adapter, so it's covered by each
  consumer's browser/integration verification.
  """

  # async: false — perform's failure path broadcasts on the shared global topic.
  use ExUnit.Case, async: false

  alias PhoenixKitAI.{TranslateWorker, Translations}

  describe "retryable?/1" do
    test "transient AI errors retry" do
      assert TranslateWorker.retryable?({:ai_error, :request_timeout})
      assert TranslateWorker.retryable?({:ai_error, :timeout})
      assert TranslateWorker.retryable?({:ai_error, :rate_limited})
      assert TranslateWorker.retryable?({:ai_error, {:connection_error, :closed}})
      assert TranslateWorker.retryable?({:ai_error, {:exit, :timeout}})
    end

    test "5xx-class + 429 API errors retry; other 4xx don't" do
      assert TranslateWorker.retryable?({:ai_error, {:api_error, 500}})
      assert TranslateWorker.retryable?({:ai_error, {:api_error, 503}})
      # 429 retries as defense-in-depth: the built-in client maps 429 →
      # :rate_limited (snoozed), but a custom provider may surface {:api_error, 429}.
      assert TranslateWorker.retryable?({:ai_error, {:api_error, 429}})
      refute TranslateWorker.retryable?({:ai_error, {:api_error, 400}})
      refute TranslateWorker.retryable?({:ai_error, {:api_error, 404}})
    end

    test "deterministic errors don't retry" do
      refute TranslateWorker.retryable?({:parse_error, :no_markers})
      refute TranslateWorker.retryable?(:ai_not_installed)
      refute TranslateWorker.retryable?({:no_adapter, "x"})
      refute TranslateWorker.retryable?(:anything_else)
    end
  end

  describe "perform/1 setup failures (no AI call)" do
    test "missing required arg → discard with {:missing_arg, _}" do
      job = %Oban.Job{args: %{"resource_uuid" => "u"}, attempt: 1, max_attempts: 3}
      assert {:discard, {:missing_arg, "resource_type"}} = TranslateWorker.perform(job)
    end

    test "unknown resource type → discard {:no_adapter, _} + failure broadcast" do
      :ok = Translations.subscribe()

      job = %Oban.Job{
        args: %{
          "resource_type" => "totally_unregistered",
          "resource_uuid" => "00000000-0000-0000-0000-0000000000b1",
          "endpoint_uuid" => "e",
          "prompt_uuid" => "p",
          "source_lang" => "en",
          "target_lang" => "es"
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:discard, {:no_adapter, "totally_unregistered"}} = TranslateWorker.perform(job)

      assert_receive {:ai_translation, :translation_failed, payload}
      assert payload.resource_type == "totally_unregistered"
      assert payload.target_lang == "es"
      assert payload.reason == {:no_adapter, "totally_unregistered"}
    end
  end
end
