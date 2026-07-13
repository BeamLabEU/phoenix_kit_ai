defmodule PhoenixKitAI.LegacyApiKeyMigrationTest do
  @moduledoc """
  Tests for `PhoenixKitAI.run_legacy_api_key_migration/0` — the
  one-shot auto-migrator that folds pre-Integrations endpoint api_keys
  into named `PhoenixKit.Integrations` connections.

  Designed for "0 chance of breaking anything" so the test surface
  matches: every idempotency guard pinned, partial-state preservation
  pinned, post-migration legacy-fallback safety net pinned.

  `async: false` because the migration writes to global Settings
  (`ai_legacy_api_key_migration_completed_at`) and to global
  `phoenix_kit_settings` integration keys, both of which would race
  against parallel tests.
  """

  use PhoenixKitAI.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    # Each test starts from a clean integration / completion-flag state.
    # The DataCase sandbox rolls back at test exit but explicit cleanup
    # here makes intent obvious.
    :ok = clear_integration_keys()
    :ok = clear_completion_flag()
    :ok
  end

  defp clear_integration_keys do
    SQL.query!(
      TestRepo,
      "DELETE FROM phoenix_kit_settings WHERE key LIKE 'integration:openrouter:%' OR (module = 'integrations' AND value_json->>'provider' = 'openrouter')"
    )

    :ok
  end

  defp clear_completion_flag do
    Settings.delete_setting("ai_legacy_api_key_migration_completed_at")
    :ok
  rescue
    _ -> :ok
  end

  defp legacy_endpoint_fixture(api_key, attrs \\ %{}) do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Legacy-#{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "a/b",
            api_key: api_key
          },
          Map.new(attrs)
        )
      )

    ep
  end

  describe "idempotency guards" do
    test "noop when completion flag is already set" do
      Settings.update_setting_with_module(
        "ai_legacy_api_key_migration_completed_at",
        DateTime.utc_now() |> DateTime.to_iso8601(),
        "ai"
      )

      ep = legacy_endpoint_fixture("sk-already-flagged")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      # Endpoint untouched — provider stays bare "openrouter".
      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.provider == "openrouter"

      # No integration created.
      assert {:error, :not_configured} = Integrations.get_credentials("openrouter:default")
    end

    test "noop when an openrouter integration already exists" do
      # Operator already set up a connection manually before the
      # migration ran — the migration should mark itself complete and
      # leave everything else alone.
      {:ok, _} = Integrations.add_connection("openrouter", "manual-setup")

      ep = legacy_endpoint_fixture("sk-existing-integration")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)

      assert reloaded.provider == "openrouter",
             "expected migration to skip when existing integration found"

      # Completion flag now set so subsequent calls are also no-ops.
      assert is_binary(Settings.get_setting("ai_legacy_api_key_migration_completed_at", nil))
    end

    test "noop when no endpoints have a legacy api_key" do
      # No endpoints in DB — migration runs but has nothing to do.
      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      # Completion flag set → second call is also a no-op.
      assert is_binary(Settings.get_setting("ai_legacy_api_key_migration_completed_at", nil))
    end

    test "second call after a real migration is a clean no-op" do
      ep = legacy_endpoint_fixture("sk-second-call")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()
      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      # Endpoint still pointing at the migrated connection (not
      # re-migrated to a new name).
      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.provider == "openrouter:default"
    end
  end

  describe "single-key deployment (most common case)" do
    test "successful migration emits a Logger.info summary" do
      # Pin the Logger.info "[PhoenixKitAI] Auto-migrated N endpoint(s)"
      # branch — fires only on the {:migrated, count} return from
      # do_run_legacy_api_key_migration/0. Test config sets
      # `level: :warning` which filters info BEFORE capture_log sees
      # it, so we lift the global level for this test (workspace
      # AGENTS.md "Logger.level must be lifted" trap).
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      _ep = legacy_endpoint_fixture("sk-log-test")

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = PhoenixKitAI.run_legacy_api_key_migration()
        end)

      assert log =~ "Auto-migrated 1 endpoint(s) from legacy api_key"
    end

    test "single endpoint with one api_key migrates to openrouter:default" do
      ep = legacy_endpoint_fixture("sk-only-key")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      # Endpoint's provider now points at the new named connection.
      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.provider == "openrouter:default"

      # Legacy api_key column cleared — credential lives in the
      # integration row now (atomic with the integration_uuid set).
      assert reloaded.api_key == ""

      # Integrations connection actually carries the key.
      assert {:ok, %{"api_key" => "sk-only-key"}} =
               Integrations.get_credentials("openrouter:default")
    end

    test "multiple endpoints with the SAME api_key share one integration" do
      ep1 = legacy_endpoint_fixture("sk-shared")
      ep2 = legacy_endpoint_fixture("sk-shared")
      ep3 = legacy_endpoint_fixture("sk-shared")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      for ep <- [ep1, ep2, ep3] do
        reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)

        assert reloaded.provider == "openrouter:default",
               "expected #{ep.name} to point at the shared connection"

        # Atomic clear: every endpoint in the group has its legacy
        # api_key wiped in the same UPDATE that linked it to the
        # integration. Group dedup → one integration row holds the
        # shared key; per-endpoint duplicates would only rot.
        assert reloaded.api_key == "",
               "expected #{ep.name} legacy api_key to be cleared"

        assert is_binary(reloaded.integration_uuid)
      end

      # Only ONE integration created (dedup by api_key value). Storage is
      # uuid-keyed since core V114 — assert through the Integrations API,
      # not raw composite keys.
      connections = PhoenixKit.Integrations.list_connections("openrouter")

      assert length(connections) == 1
      assert hd(connections).name == "default"
    end
  end

  describe "multi-key deployment" do
    test "endpoints with different api_keys get distinct imported-N connections" do
      ep_a = legacy_endpoint_fixture("sk-key-A")
      ep_b = legacy_endpoint_fixture("sk-key-B")
      ep_c = legacy_endpoint_fixture("sk-key-C")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      # Each distinct key becomes its own imported-N connection.
      reloaded_a = PhoenixKitAI.get_endpoint!(ep_a.uuid)
      reloaded_b = PhoenixKitAI.get_endpoint!(ep_b.uuid)
      reloaded_c = PhoenixKitAI.get_endpoint!(ep_c.uuid)

      providers = MapSet.new([reloaded_a.provider, reloaded_b.provider, reloaded_c.provider])

      # Three distinct connection names assigned (order isn't
      # guaranteed because group_by/Enum.with_index sees the map's
      # iteration order).
      assert MapSet.size(providers) == 3

      for provider <- providers do
        assert provider in [
                 "openrouter:imported-1",
                 "openrouter:imported-2",
                 "openrouter:imported-3"
               ]
      end

      # Every endpoint had its legacy api_key column cleared and was
      # linked to a distinct integration.
      for reloaded <- [reloaded_a, reloaded_b, reloaded_c] do
        assert reloaded.api_key == ""
        assert is_binary(reloaded.integration_uuid)
      end

      # Three distinct integration uuids — no accidental sharing
      # across the imported groups.
      uuids =
        MapSet.new([
          reloaded_a.integration_uuid,
          reloaded_b.integration_uuid,
          reloaded_c.integration_uuid
        ])

      assert MapSet.size(uuids) == 3

      # Three integration connections created in storage (uuid-keyed
      # since core V114 — count through the Integrations API).
      assert length(PhoenixKit.Integrations.list_connections("openrouter")) == 3
    end
  end

  describe "skip rules — only bare provider == \"openrouter\" gets migrated" do
    test "endpoints already pointing at named connections are NOT touched" do
      # Pretend operator already migrated this one by hand.
      ep_named = legacy_endpoint_fixture("sk-named", provider: "openrouter:my-personal")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      reloaded = PhoenixKitAI.get_endpoint!(ep_named.uuid)
      # Provider unchanged.
      assert reloaded.provider == "openrouter:my-personal"
    end

    test "mixed deployment — only bare-provider endpoints with a key get migrated" do
      bare = legacy_endpoint_fixture("sk-bare-1")
      named = legacy_endpoint_fixture("sk-named-2", provider: "openrouter:hand-crafted")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      # `bare` migrated.
      assert PhoenixKitAI.get_endpoint!(bare.uuid).provider == "openrouter:default"
      # `named` left alone.
      assert PhoenixKitAI.get_endpoint!(named.uuid).provider == "openrouter:hand-crafted"
    end

    # Note: the "empty api_key" branch in the migration's `where` clause
    # (`e.api_key != ""`) is defensive. Production data can't reach that
    # state — `api_key` is NOT NULL in core's V34 and Ecto's `cast/3`
    # strips `""` to nil before insert (which the NOT NULL constraint
    # then rejects). The branch exists in case a future schema change
    # ever loosens the constraint, not because there are real rows to
    # cover. Marked as known residual.
  end

  describe "safety-net guarantees" do
    test "the legacy api_key column IS cleared after a successful migration" do
      # Once `migrate_endpoint_group` has created an integration row
      # carrying the endpoint's api_key AND linked the endpoint via
      # `integration_uuid`, the legacy column is redundant — the
      # integration row is the canonical credential source. Keeping a
      # duplicate on the endpoint would silently rot (admin rotates
      # the integration's key, the legacy column drifts; broken
      # integration silently masked by stale fallback). Atomic clear
      # in `update_endpoints_provider/3` removes the redundancy.
      ep = legacy_endpoint_fixture("sk-will-be-cleared")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)

      assert reloaded.api_key == "",
             "expected migration to clear the legacy column once integration_uuid is set"

      # The credential is still reachable — via the integration row.
      assert {:ok, %{"api_key" => "sk-will-be-cleared"}} =
               PhoenixKit.Integrations.get_credentials(reloaded.integration_uuid)
    end

    test "function returns :ok even when called from a process with no Integrations module loaded" do
      # We can't actually unload Code.ensure_loaded?, but we can
      # exercise the safe-rescue shell to confirm it doesn't crash on
      # ANY exception path. Drop a table the migration relies on to
      # simulate a generic failure.
      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_ai_endpoints CASCADE")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()
    end

    test "credentials migration also populates integration_uuid" do
      ep = legacy_endpoint_fixture("sk-uuid-stamped")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.provider == "openrouter:default"
      assert is_binary(reloaded.integration_uuid)

      # The stamped uuid points at the new integration row.
      [%{uuid: integration_uuid}] = Integrations.list_connections("openrouter")
      assert reloaded.integration_uuid == integration_uuid
    end

    test "post-migration request flow resolves through the integration, not the legacy column" do
      # End-to-end: legacy endpoint → migrate → build_headers_from_endpoint
      # must use the integration row's api_key (the legacy column is
      # now empty). This pins that the migration's atomic clear is
      # safe — credentials are still reachable, just via the
      # canonical path.
      alias PhoenixKitAI.OpenRouterClient

      ep = legacy_endpoint_fixture("sk-end-to-end")

      assert :ok = PhoenixKitAI.run_legacy_api_key_migration()

      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.api_key == ""
      assert is_binary(reloaded.integration_uuid)

      # Resolver picks the integration_uuid path (tier 1) because
      # integration_uuid is set. If the legacy column were still
      # populated, this would still pass — the new test pins that
      # the OUTPUT is correct even with no fallback available.
      headers = OpenRouterClient.build_headers_from_endpoint(reloaded)
      assert {"Authorization", "Bearer sk-end-to-end"} in headers
    end
  end

  describe "migrate_legacy/0 — combined entry point" do
    test "returns {:ok, summary} with both migration kinds reported" do
      # Empty state — nothing to migrate. The contract is that BOTH
      # passes are attempted and the summary shape includes both.
      {:ok, summary} = PhoenixKitAI.migrate_legacy()

      assert is_map(summary)
      assert Map.has_key?(summary, :credentials_migration)
      assert Map.has_key?(summary, :reference_migration)
    end

    test "credentials migration pass runs as part of migrate_legacy/0" do
      # Bare-provider endpoint with an api_key — the credentials
      # migration target. After migrate_legacy/0 it should be pinned
      # via integration_uuid (NOT just provider) — same shape the
      # standalone run_legacy_api_key_migration/0 produces.
      ep = legacy_endpoint_fixture("sk-via-combined")

      {:ok, _summary} = PhoenixKitAI.migrate_legacy()

      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.provider == "openrouter:default"
      assert is_binary(reloaded.integration_uuid)
    end

    test "reference sweep pass promotes provider:name → integration_uuid" do
      # Pre-stage: a manual integration row exists (operator set it
      # up themselves, so the credentials-migration guard fires and
      # skips that pass — but the reference sweep should still
      # promote the string-referenced endpoint).
      {:ok, _} = Integrations.add_connection("openrouter", "manual")
      [%{uuid: manual_uuid}] = Integrations.list_connections("openrouter")

      ep =
        legacy_endpoint_fixture("ignored-key", %{
          name: "StringRefEndpoint",
          provider: "openrouter:manual"
        })

      # Reset integration_uuid to nil so the sweep has work to do.
      SQL.query!(
        TestRepo,
        "UPDATE phoenix_kit_ai_endpoints SET integration_uuid = NULL WHERE uuid = $1",
        [Ecto.UUID.dump!(ep.uuid)]
      )

      {:ok, _summary} = PhoenixKitAI.migrate_legacy()

      reloaded = PhoenixKitAI.get_endpoint!(ep.uuid)
      assert reloaded.integration_uuid == manual_uuid
    end

    test "returns either {:ok, _} or {:error, _} on infrastructure failure" do
      # Drop the endpoints table so both passes fail. The function
      # MUST NOT raise — orchestrator can't recover from a raised exception.
      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_ai_endpoints CASCADE")

      result = PhoenixKitAI.migrate_legacy()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
