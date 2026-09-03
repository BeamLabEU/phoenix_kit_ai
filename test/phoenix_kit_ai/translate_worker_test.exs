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

  `PhoenixKitAI.DataCase` (not a plain `ExUnit.Case`) because `perform/1`'s
  setup-failure branch now writes an `ai.translation_failed` activity entry
  (best-effort) alongside its broadcast — without a checked-out sandbox
  connection, that Ecto call can race a concurrently-shutting-down async
  test's owner process and take this test process down with an unrescuable
  `:exit` (a link-level kill signal, not something `try/rescue/catch` can
  intercept — see `translate_worker_failure_logging_test.exs` for the
  deterministic, changeset-level version of "the logger itself fails" this
  race isn't needed to prove).
  """

  # async: false — perform's failure path broadcasts on the shared global topic.
  use PhoenixKitAI.DataCase, async: false

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

    test "§9.5: missing_fields retries as insurance against model non-determinism" do
      assert TranslateWorker.retryable?({:parse_error, {:missing_fields, ["title"]}})
      assert TranslateWorker.retryable?({:parse_error, {:missing_fields, ["title", "body"]}})
    end

    test "§9.5 is scoped to missing_fields — other parse errors stay deterministic" do
      # A prompt rendered with no markers at all, or with two field names
      # colliding on the same marker, isn't "the model forgot a field" —
      # it's structural, and retrying burns 2 more attempts for the exact
      # same outcome.
      refute TranslateWorker.retryable?({:parse_error, :no_markers})
      refute TranslateWorker.retryable?({:parse_error, {:duplicate_markers, ["TITLE"]}})
    end
  end

  describe "safe_put_translation/3 — §9.3 source_fields threading" do
    # Public-for-testing seam (see the `@doc false` on the function itself).
    # A hand-rolled ctx map exercises exactly the four keys the function
    # reads — no live adapter registration or DB row needed.

    defmodule RecordingAdapter do
      @moduledoc false
      def put_translation(resource, target_lang, fields, opts) do
        {:ok, %{resource: resource, target_lang: target_lang, fields: fields, opts: opts}}
      end
    end

    defmodule FailingAdapter do
      @moduledoc false
      def put_translation(_resource, _target_lang, _fields, _opts) do
        {:error, :changeset_invalid}
      end
    end

    defmodule CrashingAdapter do
      @moduledoc false
      def put_translation(_resource, _target_lang, _fields, _opts) do
        raise "adapter blew up"
      end
    end

    defmodule OffContractAdapter do
      @moduledoc false
      def put_translation(_resource, _target_lang, _fields, _opts), do: :not_a_result_tuple
    end

    test "threads source_fields into the adapter's opts alongside actor_uuid" do
      ctx = %{adapter: RecordingAdapter, resource: %{id: 1}, target: "es", actor: "actor-uuid"}
      source_fields = %{"title" => "Widget", "body" => "A fine widget."}

      assert {:ok, %{opts: opts}} =
               TranslateWorker.safe_put_translation(
                 ctx,
                 %{"title" => "Widget-es"},
                 source_fields
               )

      assert Keyword.get(opts, :source_fields) == source_fields
      assert Keyword.get(opts, :actor_uuid) == "actor-uuid"
    end

    test "passes resource, target_lang and translated fields through unchanged" do
      ctx = %{adapter: RecordingAdapter, resource: %{id: 42}, target: "fr", actor: nil}

      assert {:ok, %{resource: resource, target_lang: target_lang, fields: fields}} =
               TranslateWorker.safe_put_translation(ctx, %{"title" => "Widget-fr"}, %{
                 "title" => "Widget"
               })

      assert resource == %{id: 42}
      assert target_lang == "fr"
      assert fields == %{"title" => "Widget-fr"}
    end

    test "an empty source_fields map still lands in opts (not dropped as falsy)" do
      ctx = %{adapter: RecordingAdapter, resource: %{id: 1}, target: "es", actor: nil}

      assert {:ok, %{opts: opts}} =
               TranslateWorker.safe_put_translation(ctx, %{"title" => "x"}, %{})

      assert Keyword.get(opts, :source_fields) == %{}
    end

    test "adapter {:error, _} passes through unchanged" do
      ctx = %{adapter: FailingAdapter, resource: %{id: 1}, target: "es", actor: nil}

      assert {:error, :changeset_invalid} =
               TranslateWorker.safe_put_translation(ctx, %{"title" => "x"}, %{})
    end

    test "adapter raising is caught and normalised to {:exception, message}" do
      ctx = %{adapter: CrashingAdapter, resource: %{id: 1}, target: "es", actor: nil}

      assert {:error, {:exception, message}} =
               TranslateWorker.safe_put_translation(ctx, %{"title" => "x"}, %{})

      assert message =~ "adapter blew up"
    end

    test "adapter returning an off-contract value is wrapped as {:bad_put_translation, _}" do
      ctx = %{adapter: OffContractAdapter, resource: %{id: 1}, target: "es", actor: nil}

      assert {:error, {:bad_put_translation, :not_a_result_tuple}} =
               TranslateWorker.safe_put_translation(ctx, %{"title" => "x"}, %{})
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
