defmodule PhoenixKitAI.TranslateWorkerFailureClassificationTest do
  @moduledoc """
  Unit coverage for `PhoenixKitAI.TranslateWorker.classify_reason/1` — the
  function that reduces a failure `reason` term to the short, static
  `{category, detail}` pair written into the `ai.translation_failed`
  activity entry's metadata (see `translate_worker_failure_logging_test.exs`
  for the DB-backed proof that the entry actually lands).

  No DB, no PubSub, no adapter — pure function, runs unconditionally.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.TranslateWorker

  describe "classify_reason/1 — perform/1 setup-failure reasons" do
    test "missing_arg carries the missing key name" do
      assert TranslateWorker.classify_reason({:missing_arg, "resource_type"}) ==
               {"invalid_args", "resource_type"}
    end

    test "no_adapter carries the unresolved resource_type" do
      assert TranslateWorker.classify_reason({:no_adapter, "widget"}) ==
               {"no_adapter", "widget"}
    end

    test "bad_adapter_fetch drops the adapter's raw return value" do
      assert TranslateWorker.classify_reason({:bad_adapter_fetch, {:weird, "payload"}}) ==
               {"adapter_error", "bad_fetch_result"}
    end
  end

  describe "classify_reason/1 — do_translate/fail reasons" do
    test "the reported bug: parse_error/no_markers" do
      assert TranslateWorker.classify_reason({:parse_error, :no_markers}) ==
               {"parse_error", "no_markers"}
    end

    test "the other parse_error shapes" do
      assert TranslateWorker.classify_reason({:parse_error, {:missing_fields, ["body"]}}) ==
               {"parse_error", "missing_fields"}

      assert TranslateWorker.classify_reason({:parse_error, {:duplicate_markers, ["NAME"]}}) ==
               {"parse_error", "duplicate_markers"}
    end

    test "adapter_error wraps a bad source_fields return, non-string fields, or a crash" do
      assert TranslateWorker.classify_reason({:adapter_error, :non_string_fields}) ==
               {"adapter_error", "non_string_fields"}

      assert TranslateWorker.classify_reason({:adapter_error, {:bad_source_fields, %{}}}) ==
               {"adapter_error", "bad_source_fields"}

      assert TranslateWorker.classify_reason({:adapter_error, {:exception, "boom"}}) ==
               {"adapter_error", "exception"}
    end

    test "persist_error has no detail — the adapter's return value is never serialized" do
      assert TranslateWorker.classify_reason({:persist_error, %{}}) == {"persist_error", nil}
    end

    test "persist_error wrapping a bad_put_translation or exception shape carries that detail" do
      # `persist/2` always wraps `safe_put_translation/2`'s error as
      # `{:persist_error, reason}` — this is the shape that actually reaches
      # `classify_reason/1` in production, not a bare `{:bad_put_translation,
      # _}` tuple.
      assert TranslateWorker.classify_reason({:persist_error, {:bad_put_translation, :whatever}}) ==
               {"persist_error", "bad_put_translation"}

      assert TranslateWorker.classify_reason({:persist_error, {:exception, "boom"}}) ==
               {"persist_error", "exception"}
    end

    test "ai_error normalises the transient provider failures" do
      assert TranslateWorker.classify_reason({:ai_error, :rate_limited}) ==
               {"ai_error", "rate_limited"}

      assert TranslateWorker.classify_reason({:ai_error, {:api_error, 503}}) ==
               {"ai_error", "api_error_503"}

      assert TranslateWorker.classify_reason({:ai_error, {:connection_error, :closed}}) ==
               {"ai_error", "connection_error"}
    end
  end

  describe "classify_reason/1 — unrecognised shapes" do
    test "a bare atom reason falls back to its own name" do
      assert TranslateWorker.classify_reason(:something_new) == {"error", "something_new"}
    end

    test "an unrecognised tagged tuple falls back to its tag" do
      assert TranslateWorker.classify_reason({:some_future_tag, "detail"}) ==
               {"error", "some_future_tag"}
    end

    test "anything else (a string, a map, ...) is fully unclassified" do
      assert TranslateWorker.classify_reason("a bare string reason") == {"error", "unclassified"}
      assert TranslateWorker.classify_reason(%{not: "a tuple"}) == {"error", "unclassified"}
    end
  end

  describe "classify_reason/1 — no sensitive payload ever survives" do
    test "adapter/provider-supplied content never appears in the classification" do
      secret = "sk-super-secret-api-token-should-never-appear"

      reasons = [
        {:bad_adapter_fetch, secret},
        {:adapter_error, {:bad_source_fields, %{"body" => secret}}},
        {:adapter_error, {:exception, secret}},
        {:adapter_error, secret},
        {:persist_error, %{message: secret}},
        {:persist_error, {:bad_put_translation, secret}},
        {:persist_error, {:exception, secret}},
        {:parse_error, {:missing_fields, [secret]}},
        {:parse_error, {:duplicate_markers, [secret]}},
        {:parse_error, secret}
      ]

      for reason <- reasons do
        {category, detail} = TranslateWorker.classify_reason(reason)

        refute String.contains?(category, secret),
               "category leaked the payload for #{inspect(reason)}"

        refute is_binary(detail) and String.contains?(detail, secret),
               "detail leaked the payload for #{inspect(reason)}"
      end
    end
  end
end
