defmodule PhoenixKitAI.TranslateWorkerFailureLoggingTest do
  @moduledoc """
  DB-backed proof that `PhoenixKitAI.TranslateWorker` writes an
  `ai.translation_failed` activity entry on a terminal failure — the gap
  this change closes. Before this, only `ai.translation_added` (the
  success path, `translate_worker.ex:293` at the time this suite was
  written) ever reached `phoenix_kit_activities`; an operator watching six
  enqueued translations had no way to see the one that discarded short of
  querying `oban_jobs` directly.

  Covers both terminal-discard sites in the worker:

    * `perform/1`'s setup-failure branch (bad args / unknown adapter /
      missing resource) — before any adapter or AI call.
    * `fail/3`, reached via `do_translate/1` — the same function the
      reported production bug (oban job 308046, `{:parse_error,
      :no_markers}`) went through. Driven here through a deterministic,
      network-free `non_string_fields` failure via `FakeTranslatable`
      (same `fail/3` clause, no live AI endpoint needed).

  `classify_reason/1`'s own mapping (incl. the literal `parse_error` /
  `no_markers` case and the no-leakage guarantee) is unit-tested in
  `translate_worker_failure_classification_test.exs` — this file only
  proves the entry actually lands with that classification.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Test.FakeTranslatable
  alias PhoenixKitAI.TranslateWorker

  describe "perform/1 setup-failure branch" do
    test "an unresolvable adapter logs ai.translation_failed with a no_adapter classification" do
      uuid = Ecto.UUID.generate()

      job = %Oban.Job{
        args: %{
          "resource_type" => "totally_unregistered_for_activity_test",
          "resource_uuid" => uuid,
          "endpoint_uuid" => Ecto.UUID.generate(),
          "prompt_uuid" => Ecto.UUID.generate(),
          "source_lang" => "en",
          "target_lang" => "es",
          "actor_uuid" => nil
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:discard, {:no_adapter, "totally_unregistered_for_activity_test"}} =
               TranslateWorker.perform(job)

      row =
        assert_activity_logged("ai.translation_failed",
          resource_uuid: uuid,
          metadata_has: %{
            "reason" => "no_adapter",
            "reason_detail" => "totally_unregistered_for_activity_test",
            "source_lang" => "en",
            "target_lang" => "es"
          }
        )

      assert row.resource_type == "totally_unregistered_for_activity_test"
      assert row.module == "ai"
      assert row.mode == "auto"
    end

    test "a missing required arg still logs, with resource_type/uuid absent from the row" do
      # No "resource_uuid" key at all — `resource_uuid` on the activity row
      # stays nil, which the `Ecto.UUID` field accepts. A non-UUID string
      # here would instead fail the entry's own changeset cast (see the
      # "malformed resource_uuid" test below for that failure mode).
      job = %Oban.Job{args: %{}, attempt: 1, max_attempts: 3}

      assert {:discard, {:missing_arg, "resource_type"}} = TranslateWorker.perform(job)

      assert_activity_logged("ai.translation_failed",
        metadata_has: %{"reason" => "invalid_args", "reason_detail" => "resource_type"}
      )
    end

    test "a malformed resource_uuid fails the activity write but the discard is unchanged" do
      # `resource_uuid` is a real column (`Ecto.UUID`) on `phoenix_kit_activities`
      # — a non-UUID string fails `Entry.changeset/2`'s cast, so
      # `PhoenixKit.Activity.log/1` returns `{:error, changeset}` (handled in
      # its own `case`, no exception at all) instead of inserting a row.
      # This is the deterministic, non-racy sibling of "the logger itself can
      # fail": unlike a connection/ownership failure (timing-dependent, and
      # not a shape `perform/1` can hit in production — Oban runs against a
      # normal pool, never the test-only Sandbox), a bad changeset is a
      # reliable way to make `log_failed/2`'s write fail on every run. Either
      # way, `TranslateWorker`'s own outcome must not depend on whether the
      # audit entry landed.
      job = %Oban.Job{
        args: %{
          "resource_type" => "totally_unregistered_bad_uuid",
          "resource_uuid" => "not-a-real-uuid",
          "endpoint_uuid" => Ecto.UUID.generate(),
          "prompt_uuid" => Ecto.UUID.generate(),
          "source_lang" => "en",
          "target_lang" => "es"
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:discard, {:no_adapter, "totally_unregistered_bad_uuid"}} =
               TranslateWorker.perform(job)

      refute_activity_logged("ai.translation_failed",
        metadata_has: %{"reason_detail" => "totally_unregistered_bad_uuid"}
      )
    end
  end

  describe "fail/3, reached via do_translate/1 (deterministic adapter failure, no AI call)" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(FakeTranslatable)
      on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(FakeTranslatable) end)
      :ok
    end

    test "a non-string source_fields map discards and logs an adapter_error classification" do
      uuid = Ecto.UUID.generate()

      job = %Oban.Job{
        args: %{
          "resource_type" => FakeTranslatable.resource_type(),
          "resource_uuid" => uuid,
          "endpoint_uuid" => Ecto.UUID.generate(),
          "prompt_uuid" => Ecto.UUID.generate(),
          "source_lang" => "en",
          "target_lang" => "fr",
          "actor_uuid" => nil
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:discard, {:adapter_error, :non_string_fields}} = TranslateWorker.perform(job)

      assert_activity_logged("ai.translation_failed",
        resource_uuid: uuid,
        metadata_has: %{
          "reason" => "adapter_error",
          "reason_detail" => "non_string_fields",
          "source_lang" => "en",
          "target_lang" => "fr"
        }
      )
    end

    test "resource_scope rides along in metadata, same as the success-path entry" do
      uuid = Ecto.UUID.generate()

      job = %Oban.Job{
        args: %{
          "resource_type" => FakeTranslatable.resource_type(),
          "resource_uuid" => uuid,
          "endpoint_uuid" => Ecto.UUID.generate(),
          "prompt_uuid" => Ecto.UUID.generate(),
          "source_lang" => "en",
          "target_lang" => "fr",
          "resource_scope" => "v2"
        },
        attempt: 1,
        max_attempts: 3
      }

      assert {:discard, {:adapter_error, :non_string_fields}} = TranslateWorker.perform(job)

      assert_activity_logged("ai.translation_failed",
        resource_uuid: uuid,
        metadata_has: %{"resource_scope" => "v2"}
      )
    end
  end
end
