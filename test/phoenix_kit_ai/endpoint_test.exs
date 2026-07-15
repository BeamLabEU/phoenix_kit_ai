defmodule PhoenixKitAI.EndpointTest do
  # async: false — see comment in prompt_changeset_test.exs
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Endpoint

  describe "changeset/2 — validation" do
    test "requires name and model (provider has a default)" do
      changeset = Endpoint.changeset(%Endpoint{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:name]
      assert errors[:model]
      # provider defaults to "openrouter" from the schema, so validate_required
      # passes even when the caller doesn't provide one.
      refute errors[:provider]
    end

    test "rejects an explicit nil provider" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: nil,
          model: "a/b",
          api_key: "sk-test-key"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:provider]
    end

    test "accepts a minimal valid endpoint" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Minimal",
          provider: "openrouter",
          model: "anthropic/claude-3-haiku",
          api_key: "sk-test-key"
        })

      assert changeset.valid?
    end

    test "rejects temperature outside [0, 2]" do
      too_low =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b",
          temperature: -0.1
        })

      too_high =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b",
          temperature: 2.5
        })

      refute too_low.valid?
      refute too_high.valid?
      assert errors_on(too_low)[:temperature]
      assert errors_on(too_high)[:temperature]
    end

    test "allows an empty api_key (legacy rows) as long as provider is set" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "No key",
          provider: "openrouter",
          model: "a/b",
          api_key: nil
        })

      assert changeset.valid?
    end

    test "empty reasoning_effort skips the inclusion check" do
      # Ecto's `cast/3` strips `""` → `nil`, so passing
      # `reasoning_effort: ""` in params would route through the
      # `nil` clause. Set the field on the struct directly so
      # `get_field/2` falls back to `""`, hitting the `"" -> changeset`
      # clause specifically (workspace AGENTS.md "Coverage push pattern"
      # struct-data fall-through technique).
      changeset =
        Endpoint.changeset(
          %Endpoint{reasoning_effort: ""},
          %{
            name: "Reasoning Probe #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "a/b"
          }
        )

      assert changeset.valid?
      refute errors_on(changeset)[:reasoning_effort]
    end

    test "changeset with explicitly-nil temperature passes the validate_temperature nil clause" do
      # Pin the `nil -> changeset` clause of validate_temperature/1.
      # The schema sets `default: 0.7` for temperature, so a fresh
      # struct's `get_field(:temperature)` returns 0.7. To hit the nil
      # branch we set it on the struct explicitly to nil.
      changeset =
        Endpoint.changeset(
          %Endpoint{temperature: nil},
          %{
            name: "NilTemp Probe #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "a/b"
          }
        )

      assert changeset.valid?
    end

    test "non-integer reasoning_max_tokens falls through silently" do
      # Pin the `_ -> changeset` fall-through of validate_reasoning_max_tokens/1.
      # Bypass cast/3's normalisation by setting the field directly on
      # the struct as a non-integer value (`get_field/2` returns it
      # unchanged for the validation step). This hits the `_` clause
      # which keeps the changeset clean — the validator deliberately
      # doesn't double-up on cast errors when the type is wrong.
      changeset =
        Endpoint.changeset(
          %Endpoint{reasoning_max_tokens: %{not: "an_int"}},
          %{
            name: "ReasonMaxTokens Probe #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "a/b"
          }
        )

      # Should not have a reasoning_max_tokens validation error from
      # the validator (the `_ -> changeset` clause is a no-op).
      refute errors_on(changeset)[:reasoning_max_tokens]
    end
  end

  describe "masked_api_key/1" do
    test "returns placeholder for nil and empty string" do
      assert Endpoint.masked_api_key(nil) == "Not set"
      assert Endpoint.masked_api_key("") == "Not set"
    end

    test "renders head+tail with an ellipsis for long keys" do
      # First 8 + ellipsis + last 4 — recognisable provider prefix
      # (`sk-or-v1`) retained, identifying suffix (`cdef`) retained.
      assert Endpoint.masked_api_key("sk-or-v1-1234567890abcdef") == "sk-or-v1…cdef"
    end

    test "fully masks short keys (< 14 chars) to avoid leaking most of the secret" do
      # A 13-char key with the head+tail shape would only have one
      # elided char in the middle — useless. Under the threshold we
      # collapse to bullets entirely.
      assert Endpoint.masked_api_key("abc") == "•••"
      assert Endpoint.masked_api_key("0123456789012") == "•••"
    end

    test "renders non-binary garbage as a placeholder" do
      assert Endpoint.masked_api_key(:atom) == "Not set"
      assert Endpoint.masked_api_key(123) == "Not set"
    end
  end

  describe "changeset/2 — integration_uuid field" do
    test "accepts integration_uuid alongside other fields" do
      uuid = UUIDv7.generate()

      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Pinned",
          integration_uuid: uuid,
          provider: "openrouter",
          model: "anthropic/claude-3-haiku",
          api_key: ""
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :integration_uuid) == uuid
    end

    test "integration_uuid is optional (nullable for backwards compat)" do
      # Existing endpoints created pre-V107 may have NULL
      # `integration_uuid`. The changeset doesn't require it; the form
      # should populate it via the picker, but a missing value is not
      # a validation error.
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Legacy",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :integration_uuid) == nil
    end

    test "is included in the JSON encoder allowlist" do
      uuid = UUIDv7.generate()
      endpoint = %Endpoint{name: "X", integration_uuid: uuid, provider: "openrouter"}
      json = Jason.encode!(endpoint)
      decoded = Jason.decode!(json)
      assert decoded["integration_uuid"] == uuid
    end
  end

  describe "changeset/2 — clear-on-set legacy api_key" do
    # The endpoint form's recovery card surfaces an existing
    # `endpoint.api_key` when no Integration is selected. As soon as the
    # user picks an Integration, the changeset clears the legacy column
    # in the SAME write so the runtime fallback chain (which would
    # otherwise mask config drift via the stale key) is removed.

    test "setting integration_uuid clears legacy api_key in the same changeset" do
      uuid = UUIDv7.generate()

      legacy_endpoint = %Endpoint{
        name: "Legacy",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-legacy"
      }

      changeset = Endpoint.changeset(legacy_endpoint, %{integration_uuid: uuid})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :integration_uuid) == uuid
      # The change is explicitly to "" — not just "no change" — so the
      # actual UPDATE statement wipes the column. Empty string (rather
      # than NULL) because the column is NOT NULL; both the recovery-
      # card condition and the runtime fallback chain treat "" as
      # "no fallback configured".
      assert {:ok, ""} = Ecto.Changeset.fetch_change(changeset, :api_key)
    end

    test "setting integration_uuid to empty string does NOT clear api_key" do
      # Defensive: an empty-string uuid is meaningless and shouldn't
      # trigger the destructive clear. Only a real uuid moves the
      # endpoint to "integration is the source of truth".
      legacy_endpoint = %Endpoint{
        name: "Legacy",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-legacy"
      }

      changeset = Endpoint.changeset(legacy_endpoint, %{integration_uuid: ""})

      assert :error = Ecto.Changeset.fetch_change(changeset, :api_key)
    end

    test "saving an unrelated field on an already-migrated endpoint leaves api_key alone" do
      # endpoint.integration_uuid is set, api_key is nil (already
      # migrated). Editing description must NOT touch api_key — would
      # show up as a phantom change otherwise.
      uuid = UUIDv7.generate()

      migrated_endpoint = %Endpoint{
        name: "Migrated",
        provider: "openrouter",
        model: "a/b",
        integration_uuid: uuid,
        api_key: nil
      }

      changeset =
        Endpoint.changeset(migrated_endpoint, %{description: "new description"})

      assert changeset.valid?
      assert :error = Ecto.Changeset.fetch_change(changeset, :api_key)
      assert :error = Ecto.Changeset.fetch_change(changeset, :integration_uuid)
    end

    test "saving with the same integration_uuid that's already set does NOT clear api_key" do
      # `fetch_change/2` only fires when the value is actually changing.
      # If the user submits the form without touching the picker, the
      # cast no-ops on integration_uuid and the maybe_clear guard skips.
      uuid = UUIDv7.generate()

      migrated_endpoint = %Endpoint{
        name: "Migrated",
        provider: "openrouter",
        model: "a/b",
        integration_uuid: uuid,
        # Defensive: imagine an endpoint that V107 backfilled (set
        # integration_uuid) but never went through a clear-on-save —
        # api_key column still populated. A no-op edit shouldn't
        # opportunistically clear it.
        api_key: "sk-stale-but-untouched"
      }

      changeset =
        Endpoint.changeset(migrated_endpoint, %{integration_uuid: uuid, description: "x"})

      assert :error = Ecto.Changeset.fetch_change(changeset, :api_key)
    end

    test "transitioning integration_uuid from set→nil does NOT clear api_key" do
      # Unselecting the integration (uuid → nil) is not the same as
      # selecting one. If the column is somehow still populated, leave
      # it alone — only "you explicitly chose an integration" triggers
      # the destructive clear.
      uuid = UUIDv7.generate()

      endpoint_with_both = %Endpoint{
        name: "Both",
        provider: "openrouter",
        model: "a/b",
        integration_uuid: uuid,
        api_key: "sk-still-here"
      }

      changeset = Endpoint.changeset(endpoint_with_both, %{integration_uuid: nil})

      # integration_uuid clears (cast accepts nil), api_key untouched.
      assert {:ok, nil} = Ecto.Changeset.fetch_change(changeset, :integration_uuid)
      assert :error = Ecto.Changeset.fetch_change(changeset, :api_key)
    end

    test "an invalid changeset (validation failure) doesn't matter — clear happens at cast time" do
      # The clear is wired into the changeset itself, so an invalid
      # changeset still has the clear baked in. But Repo.update/insert
      # won't run if the changeset is invalid — so api_key stays put
      # at the DB layer. This test pins the changeset shape; the
      # repo-level transaction guarantee is exercised by the
      # integration suite below.
      legacy_endpoint = %Endpoint{
        name: "Legacy",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-legacy"
      }

      uuid = UUIDv7.generate()

      changeset =
        Endpoint.changeset(legacy_endpoint, %{
          integration_uuid: uuid,
          # Empty name → invalid
          name: ""
        })

      refute changeset.valid?
      # api_key clear is staged in the changeset, but the changeset
      # won't reach the DB. Repo.update would short-circuit on errors.
      assert {:ok, ""} = Ecto.Changeset.fetch_change(changeset, :api_key)
    end
  end

  describe "create_endpoint/2 (integration)" do
    test "inserts a row and returns the struct" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Create Test",
          provider: "openrouter",
          model: "anthropic/claude-3-haiku",
          api_key: "sk-test-key"
        })

      assert endpoint.uuid
      assert endpoint.name == "Create Test"
      assert endpoint.enabled
      assert endpoint.temperature == 0.7
    end

    test "rejects duplicate names with a changeset error" do
      # Core V107 added the missing UNIQUE index on `lower(name)` —
      # `Endpoint.changeset/2`'s long-standing `unique_constraint(:name)`
      # declaration is now load-bearing. Same name (case-insensitive)
      # gets rejected as a clean changeset error instead of raising
      # `Ecto.ConstraintError` or silently coexisting.
      attrs = %{name: "Dup", provider: "openrouter", model: "a/b", api_key: "sk-test-key"}
      {:ok, _first} = PhoenixKitAI.create_endpoint(attrs)
      {:error, changeset} = PhoenixKitAI.create_endpoint(attrs)

      assert errors_on(changeset)[:name]
    end

    test "name uniqueness is case-insensitive" do
      attrs1 = %{name: "Claude", provider: "openrouter", model: "a/b", api_key: "k1"}
      attrs2 = %{name: "claude", provider: "openrouter", model: "a/b", api_key: "k2"}

      {:ok, _first} = PhoenixKitAI.create_endpoint(attrs1)
      {:error, changeset} = PhoenixKitAI.create_endpoint(attrs2)

      assert errors_on(changeset)[:name]
    end
  end

  describe "update_endpoint/3 (integration)" do
    test "updates fields and returns the new struct" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Update Test",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      {:ok, updated} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 0.2})

      assert updated.temperature == 0.2
    end

    test "returns {:error, changeset} for invalid updates" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Invalid Update",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      {:error, changeset} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 10})

      assert errors_on(changeset)[:temperature]
    end
  end

  describe "delete_endpoint/2 (integration)" do
    test "removes the row" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Delete Test",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      {:ok, _} = PhoenixKitAI.delete_endpoint(endpoint)

      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
    end
  end

  describe "reorder_endpoints/2 (integration)" do
    test "rewrites sort_order to match the given UUID order" do
      {:ok, a} = create("Reorder A")
      {:ok, b} = create("Reorder B")
      {:ok, c} = create("Reorder C")

      :ok = PhoenixKitAI.reorder_endpoints([c.uuid, a.uuid, b.uuid])

      assert PhoenixKitAI.get_endpoint(c.uuid).sort_order == 1
      assert PhoenixKitAI.get_endpoint(a.uuid).sort_order == 2
      assert PhoenixKitAI.get_endpoint(b.uuid).sort_order == 3
    end

    test "filters out malformed UUIDs silently" do
      {:ok, a} = create("Reorder Filter A")
      {:ok, b} = create("Reorder Filter B")

      :ok = PhoenixKitAI.reorder_endpoints(["not-a-uuid", b.uuid, nil, a.uuid])

      assert PhoenixKitAI.get_endpoint(b.uuid).sort_order == 1
      assert PhoenixKitAI.get_endpoint(a.uuid).sort_order == 2
    end

    test "empty list is a no-op (returns :ok)" do
      assert PhoenixKitAI.reorder_endpoints([]) == :ok
    end

    test "rejects payloads above the 500-uuid cap" do
      uuids = for _ <- 1..501, do: Ecto.UUID.generate()
      assert {:error, :too_many_uuids} = PhoenixKitAI.reorder_endpoints(uuids)
    end

    defp create(name) do
      PhoenixKitAI.create_endpoint(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test-key"
      })
    end
  end

  describe "resolve_endpoint/1" do
    test "resolves a valid UUID string to the endpoint struct" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Resolve UUID",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      assert {:ok, found} = PhoenixKitAI.resolve_endpoint(endpoint.uuid)
      assert found.uuid == endpoint.uuid
    end

    test "returns :endpoint_not_found for a valid but non-existent UUID" do
      uuid = "01234567-89ab-7def-8000-000000000000"
      assert {:error, :endpoint_not_found} = PhoenixKitAI.resolve_endpoint(uuid)
    end

    test "returns :invalid_endpoint_identifier for nonsense input" do
      assert {:error, :invalid_endpoint_identifier} = PhoenixKitAI.resolve_endpoint(123)
      assert {:error, :invalid_endpoint_identifier} = PhoenixKitAI.resolve_endpoint(nil)
    end

    test "accepts an Endpoint struct directly" do
      endpoint = %PhoenixKitAI.Endpoint{uuid: "01234567-89ab-7def-8000-000000000000"}
      assert {:ok, ^endpoint} = PhoenixKitAI.resolve_endpoint(endpoint)
    end
  end

  describe "changeset/2 — SSRF guard on base_url" do
    # Pin the validator added 2026-04-26. Without it, an admin could
    # create an endpoint pointing at AWS cloud-metadata
    # (169.254.169.254), corporate intranet ranges, or the local
    # loopback and have the server fetch on their behalf via
    # `Completion.build_url/2` → `Req.post/2`.

    test "the openrouter default (https://openrouter.ai/api/v1) passes" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{name: "Default", provider: "openrouter", model: "a/b"})

      assert changeset.valid?
      refute errors_on(changeset)[:base_url]
    end

    test "non-http(s) schemes are rejected" do
      for url <- ["file:///etc/passwd", "gopher://x/", "ftp://x/", "javascript:alert(1)"] do
        changeset = ssrf_changeset(url)
        refute changeset.valid?, "expected #{url} to fail"
        assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ "http or https"))
      end
    end

    test "missing host is rejected" do
      changeset = ssrf_changeset("https://")
      refute changeset.valid?
      assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ "hostname"))
    end

    test "AWS cloud-metadata (169.254.169.254) is rejected" do
      changeset = ssrf_changeset("http://169.254.169.254/latest/meta-data/")
      refute changeset.valid?
      assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ "private/loopback/link-local"))
    end

    test "loopback (127.0.0.1) is rejected" do
      changeset = ssrf_changeset("http://127.0.0.1:11434/api")
      refute changeset.valid?
      assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ "private/loopback/link-local"))
    end

    test "RFC1918 ranges (10/8, 172.16/12, 192.168/16) are rejected" do
      for url <- [
            "http://10.1.2.3/",
            "http://172.16.0.1/",
            "http://172.31.255.254/",
            "http://192.168.1.1/"
          ] do
        changeset = ssrf_changeset(url)
        refute changeset.valid?, "expected #{url} to fail"

        assert errors_on(changeset)[:base_url]
               |> Enum.any?(&(&1 =~ "private/loopback/link-local"))
      end
    end

    test "RFC1918 boundaries: 172.15 and 172.32 are NOT considered private" do
      for url <- ["https://172.15.0.1/", "https://172.32.0.1/"] do
        changeset = ssrf_changeset(url)
        # Public IPs in those ranges pass.
        assert changeset.valid?, "expected #{url} to pass — boundary outside RFC1918"
      end
    end

    test "0.0.0.0 (unspecified) is rejected" do
      changeset = ssrf_changeset("http://0.0.0.0/")
      refute changeset.valid?
    end

    test "IPv6 loopback ::1 is rejected" do
      changeset = ssrf_changeset("http://[::1]/")
      refute changeset.valid?
    end

    test "IPv6 link-local fe80:: is rejected" do
      changeset = ssrf_changeset("http://[fe80::1]/")
      refute changeset.valid?
    end

    test "localhost hostname is rejected" do
      changeset = ssrf_changeset("http://localhost:11434/api")
      refute changeset.valid?
      assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ "localhost"))
    end

    test ".local mDNS hostnames are rejected" do
      changeset = ssrf_changeset("http://printer.local/api")
      refute changeset.valid?
      assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ ".local"))
    end

    test "config :allow_internal_endpoint_urls bypasses the internal-IP checks" do
      Application.put_env(:phoenix_kit_ai, :allow_internal_endpoint_urls, true)

      try do
        for url <- [
              "http://localhost:11434/api",
              "http://127.0.0.1/",
              "http://192.168.1.1/",
              "http://printer.local/"
            ] do
          changeset = ssrf_changeset(url)
          assert changeset.valid?, "expected #{url} to pass with override on"
        end

        # The scheme guard still fires even with the override on.
        changeset = ssrf_changeset("file:///etc/passwd")
        refute changeset.valid?
      after
        Application.delete_env(:phoenix_kit_ai, :allow_internal_endpoint_urls)
      end
    end

    test "public hostnames pass" do
      for url <- [
            "https://api.openai.com/v1",
            "https://openrouter.ai/api/v1",
            "https://api.anthropic.com",
            "http://example.com:8080/api"
          ] do
        changeset = ssrf_changeset(url)
        assert changeset.valid?, "expected #{url} to pass"
      end
    end

    test "IPv4-mapped IPv6 addresses do not bypass the IPv4 guard" do
      # Without the {0,0,0,0,0,0xFFFF,_,_} clause, these wrap loopback
      # and AWS metadata respectively and slip through the v4 checks.
      for url <- [
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:169.254.169.254]/",
            "http://[::ffff:10.0.0.1]/",
            "http://[::ffff:192.168.1.1]/"
          ] do
        changeset = ssrf_changeset(url)
        refute changeset.valid?, "expected #{url} to be rejected"

        assert errors_on(changeset)[:base_url]
               |> Enum.any?(&(&1 =~ "private/loopback/link-local"))
      end
    end

    test "CGNAT range 100.64.0.0/10 is rejected" do
      for url <- [
            "http://100.64.0.1/",
            "http://100.127.255.254/"
          ] do
        changeset = ssrf_changeset(url)
        refute changeset.valid?, "expected #{url} to be rejected"
      end

      # 100.63.x and 100.128.x are public — boundary checks.
      for url <- ["http://100.63.255.254/", "http://100.128.0.1/"] do
        changeset = ssrf_changeset(url)
        assert changeset.valid?, "expected #{url} to pass (outside CGNAT range)"
      end
    end

    test "trailing-dot loopback host is rejected" do
      # `127.0.0.1.` is the FQDN form of loopback. The OS resolver
      # accepts it; without normalization it slips past parse_address.
      changeset = ssrf_changeset("http://127.0.0.1./")
      refute changeset.valid?

      assert errors_on(changeset)[:base_url]
             |> Enum.any?(&(&1 =~ "private/loopback/link-local"))
    end

    test "IPv6 unspecified address `::` is rejected" do
      changeset = ssrf_changeset("http://[::]/")
      refute changeset.valid?

      assert errors_on(changeset)[:base_url]
             |> Enum.any?(&(&1 =~ "private/loopback/link-local"))
    end

    test "empty base_url passes the validate_base_url empty-string clause" do
      # Pin the `"" -> changeset` clause of validate_base_url/1. The
      # field is set on the struct so `get_field/2` returns `""`
      # directly — Ecto's `cast/3` would otherwise normalise empty
      # strings to nil before reaching the validator.
      changeset =
        Endpoint.changeset(
          %Endpoint{base_url: ""},
          %{
            name: "Empty Probe #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "a/b"
          }
        )

      base_url_errors = errors_on(changeset)[:base_url] || []

      refute Enum.any?(base_url_errors, &(&1 =~ "scheme")),
             "expected empty base_url to skip the SSRF check"
    end

    test "non-string base_url is rejected with a type error" do
      # Bypass `cast/3`'s string normalisation by setting the field
      # directly on the struct, then run the changeset on top. The
      # `_ -> add_error(:base_url, "must be a string")` clause fires.
      changeset =
        Endpoint.changeset(
          %Endpoint{base_url: %{not: "a string"}},
          %{
            name: "Bad URL Probe #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "a/b"
          }
        )

      refute changeset.valid?
      assert errors_on(changeset)[:base_url] |> Enum.any?(&(&1 =~ "must be a string"))
    end

    test "non-standard IPv4 encodings (octal, decimal-integer, hex) are rejected" do
      # OTP's `:inet.parse_address/1` currently accepts all three encodings
      # as the same IPv4 literal — e.g. `0177.0.0.1` / `2130706433` /
      # `0x7f000001` all resolve to `{127, 0, 0, 1}`. The existing
      # loopback / RFC1918 / link-local clauses then catch them.
      #
      # This test pins that rejection behaviour. If a future OTP regresses
      # and starts treating these as opaque non-literal hostnames,
      # `internal_host?/1` falls through to `false` and the SSRF guard's
      # bypass surface widens silently — this test catches that as a
      # failure rather than letting it ship.
      for url <- [
            # Octal-encoded loopback
            "http://0177.0.0.1/",
            # Decimal-integer-encoded loopback (127.0.0.1 = 2130706433)
            "http://2130706433/",
            # Hex-encoded loopback
            "http://0x7f000001/",
            # Decimal-integer-encoded AWS metadata (169.254.169.254 = 2852039166)
            "http://2852039166/",
            # Decimal-integer-encoded RFC1918 (10.0.0.1 = 167772161)
            "http://167772161/"
          ] do
        changeset = ssrf_changeset(url)

        refute changeset.valid?,
               "expected #{url} to be rejected (encoded literal IPv4 form)"

        assert errors_on(changeset)[:base_url]
               |> Enum.any?(&(&1 =~ "private/loopback/link-local")),
               "expected #{url} to fail with the private/loopback/link-local error"
      end
    end
  end

  describe "tts_model_picker?/1" do
    test "false for xai — its TTS isn't model-discoverable" do
      refute Endpoint.tts_model_picker?("xai")
    end

    test "false for a named xai connection too (xai:personal)" do
      refute Endpoint.tts_model_picker?("xai:personal")
    end

    test "true for providers whose TTS (if any) is model-based" do
      assert Endpoint.tts_model_picker?("openrouter")
      assert Endpoint.tts_model_picker?("mistral")
      assert Endpoint.tts_model_picker?("openai")
    end

    test "true for nil/non-binary (fails open — not a dead end to hide)" do
      assert Endpoint.tts_model_picker?(nil)
    end
  end

  defp ssrf_changeset(url) do
    Endpoint.changeset(%Endpoint{}, %{
      name: "SSRF Probe #{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "a/b",
      base_url: url
    })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
