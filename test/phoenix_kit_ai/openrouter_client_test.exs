defmodule PhoenixKitAI.OpenRouterClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.OpenRouterClient

  describe "fetch_embedding_models/2" do
    test "returns the built-in curated list" do
      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-test")
      assert is_list(models)
      assert length(models) >= 8

      ids = Enum.map(models, & &1["id"])
      assert "openai/text-embedding-3-large" in ids
      assert "cohere/embed-5-pro" in ids
      assert "mongodb/voyage-4" in ids
      refute "voyage/voyage-3" in ids
    end

    test "appends user-contributed models from config" do
      custom = [
        %{
          "id" => "custom/model-x",
          "name" => "Custom X",
          "description" => "Test",
          "context_length" => 2048,
          "dimensions" => 256,
          "pricing" => %{"prompt" => 0, "completion" => 0}
        }
      ]

      Application.put_env(:phoenix_kit_ai, :embedding_models, custom)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :embedding_models)
      end)

      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-test")
      ids = Enum.map(models, & &1["id"])
      assert "custom/model-x" in ids
    end

    test "tolerates malformed config (non-list)" do
      Application.put_env(:phoenix_kit_ai, :embedding_models, "not a list")

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :embedding_models)
      end)

      {:ok, models} = OpenRouterClient.fetch_embedding_models("sk-test")
      assert is_list(models)
    end
  end

  describe "embedding_models_last_updated/0" do
    test "returns a date string" do
      assert is_binary(OpenRouterClient.embedding_models_last_updated())
      assert OpenRouterClient.embedding_models_last_updated() =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end
  end

  describe "fetch_embedding_models_grouped/2" do
    test "groups the list by provider prefix" do
      {:ok, grouped} = OpenRouterClient.fetch_embedding_models_grouped("sk-test")
      assert is_list(grouped)
      providers = Enum.map(grouped, fn {p, _} -> p end)
      assert "openai" in providers
      assert "cohere" in providers
    end
  end

  describe "build_headers/2" do
    test "includes the bearer token and content type" do
      headers = OpenRouterClient.build_headers("sk-test-key")
      assert {"Authorization", "Bearer sk-test-key"} in headers
      assert Enum.any?(headers, fn {k, _} -> k == "Content-Type" end)
    end

    test "adds HTTP-Referer and X-Title when provided" do
      headers =
        OpenRouterClient.build_headers("sk-test-key",
          http_referer: "https://example.com",
          x_title: "Example"
        )

      assert {"HTTP-Referer", "https://example.com"} in headers
      assert {"X-Title", "Example"} in headers
    end

    test "percent-encodes a title or referer that is not plain ASCII" do
      headers =
        OpenRouterClient.build_headers("sk-test-key",
          http_referer: "https://пример.рф/атлас",
          x_title: "Атлас речевого мозга"
        )

      {"X-Title", title} = List.keyfind(headers, "X-Title", 0)
      {"HTTP-Referer", referer} = List.keyfind(headers, "HTTP-Referer", 0)

      for value <- [title, referer], do: assert(value =~ ~r/\A[\x21-\x7E]+\z/)
      assert URI.decode(title) == "Атлас речевого мозга"
      assert URI.decode(referer) == "https://пример.рф/атлас"
    end

    test "a percent sign in a non-ASCII title survives the round trip" do
      headers = OpenRouterClient.build_headers("sk-test-key", x_title: "50% скидка")
      {"X-Title", title} = List.keyfind(headers, "X-Title", 0)
      assert title == "50%25%20%D1%81%D0%BA%D0%B8%D0%B4%D0%BA%D0%B0"
      assert URI.decode(title) == "50% скидка"
    end

    # A title is site-admin input. CR/LF inside it must never reach the wire
    # raw (a second header line); encoded, it is one inert value.
    test "a title with a line break inside goes as one encoded value" do
      headers =
        OpenRouterClient.build_headers("sk-test-key", x_title: "Atlas\r\nX-Injected: yes\tok")

      {"X-Title", title} = List.keyfind(headers, "X-Title", 0)
      assert title =~ ~r/\A[\x21-\x7E]+\z/
      assert URI.decode(title) == "Atlas\r\nX-Injected: yes\tok"
      refute List.keymember?(headers, "X-Injected", 0)
    end

    test "a title or referer of only whitespace sends no header" do
      headers = OpenRouterClient.build_headers("sk-test-key", x_title: "  \t ", http_referer: " ")
      refute List.keymember?(headers, "X-Title", 0)
      refute List.keymember?(headers, "HTTP-Referer", 0)
    end

    test "keeps a plain ASCII title with spaces as it is" do
      headers = OpenRouterClient.build_headers("sk-test-key", x_title: "Logoped Atlas")
      assert {"X-Title", "Logoped Atlas"} in headers
    end

    test "omits optional headers when nil" do
      headers = OpenRouterClient.build_headers("sk-test-key", http_referer: nil, x_title: nil)
      refute Enum.any?(headers, fn {k, _} -> k == "HTTP-Referer" end)
      refute Enum.any?(headers, fn {k, _} -> k == "X-Title" end)
    end
  end
end

defmodule PhoenixKitAI.OpenRouterClient.LegacyFallbackTest do
  # Hits the DB through PhoenixKit.Integrations.get_credentials/1
  # to take the fallback branch, so this group needs DataCase.
  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.OpenRouterClient

  describe "build_headers_from_endpoint/1 — legacy api_key fallback" do
    # `resolve_api_key/2` falls back to `endpoint.api_key` when the
    # provider key isn't a registered integration. PR #3 added a
    # deprecation `Logger.warning` on that path identifying the
    # endpoint by name + uuid so the noise is actionable. Pin the
    # warning's content; without this test, dropping the helper or
    # silencing the log goes unnoticed.

    test "emits a deprecation warning identifying the endpoint when the legacy api_key path is used" do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000aa",
        name: "Legacy Endpoint",
        provider: "openrouter-not-registered-#{System.unique_integer([:positive])}",
        api_key: "sk-or-v1-legacy",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
          # Headers still get built — fallback path returns the
          # legacy key, not nil.
          assert {"Authorization", "Bearer sk-or-v1-legacy"} in headers
        end)

      assert log =~ "deprecated endpoint.api_key"
      assert log =~ ~s("Legacy Endpoint")
      assert log =~ endpoint.uuid
    end

    test "does NOT warn when the legacy api_key field is empty" do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000bb",
        name: "Empty Legacy",
        provider: "openrouter-not-registered-#{System.unique_integer([:positive])}",
        api_key: "",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          OpenRouterClient.build_headers_from_endpoint(endpoint)
        end)

      refute log =~ "deprecated endpoint.api_key"
    end

    test "empty provider field falls through cleanly to the legacy api_key column" do
      # Pins `maybe_get_credentials("")` — the empty-string clause.
      # An endpoint with `provider: ""` (e.g. fully-cleared after
      # operator removed the legacy reference manually) should still
      # fall through to the api_key column without crashing on the
      # empty provider lookup.
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000cc",
        name: "Empty Provider",
        provider: "",
        api_key: "sk-or-v1-fallback",
        provider_settings: %{}
      }

      headers =
        capture_log(fn ->
          # Capture log silently — the deprecation warning fires for
          # any api_key path use, but that's not what this test pins.
          assert {"Authorization", "Bearer sk-or-v1-fallback"} in OpenRouterClient.build_headers_from_endpoint(
                   endpoint
                 )
        end)

      assert is_binary(headers)
    end

    test "nil provider field also falls through to the legacy api_key column" do
      # Pins `maybe_get_credentials(nil)` — the nil clause. Same
      # shape as the empty-string case but ensures the nil-vs-empty
      # symmetry holds.
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000dd",
        name: "Nil Provider",
        provider: nil,
        api_key: "sk-or-v1-nil-fallback",
        provider_settings: %{}
      }

      capture_log(fn ->
        assert {"Authorization", "Bearer sk-or-v1-nil-fallback"} in OpenRouterClient.build_headers_from_endpoint(
                 endpoint
               )
      end)
    end
  end

  describe "build_headers_from_endpoint/1 — integration_uuid resolution" do
    # Post-V107, endpoints reference a specific integration row by
    # uuid via `integration_uuid`. `resolve_api_key/1` should prefer
    # that field over `provider` and the legacy `api_key` column.

    setup do
      # Seed an OpenRouter integration row, capture its uuid.
      {:ok, %{uuid: uuid}} = PhoenixKit.Integrations.add_connection("openrouter", "primary")
      {:ok, _} = PhoenixKit.Integrations.save_setup(uuid, %{"api_key" => "sk-uuid-resolved"})
      {:ok, integration_uuid: uuid}
    end

    test "uses integration_uuid first when set", %{integration_uuid: uuid} do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000cc",
        name: "Pinned Endpoint",
        integration_uuid: uuid,
        # Bare `provider` and a legacy `api_key` would both produce
        # different keys; integration_uuid should win over both.
        provider: "openrouter",
        api_key: "sk-legacy-LOSER",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
          assert {"Authorization", "Bearer sk-uuid-resolved"} in headers
        end)

      # No legacy warning fires — the uuid path resolved cleanly.
      refute log =~ "deprecated endpoint.api_key"
    end

    test "falls back to legacy provider field when integration_uuid is nil", %{
      integration_uuid: uuid
    } do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000dd",
        name: "Provider-as-uuid Endpoint",
        integration_uuid: nil,
        # Pre-V107 endpoints stuffed the integration uuid into the
        # `provider` string field. Resolver still accepts that shape.
        provider: uuid,
        api_key: "",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
          assert {"Authorization", "Bearer sk-uuid-resolved"} in headers
        end)

      refute log =~ "deprecated endpoint.api_key"
    end

    test "warns + falls back to api_key when both integration_uuid and provider are unresolvable" do
      endpoint = %Endpoint{
        uuid: "01234567-89ab-7def-8000-0000000000ee",
        name: "Orphan Endpoint",
        integration_uuid: nil,
        provider: "openrouter-not-registered-#{System.unique_integer([:positive])}",
        api_key: "sk-fallback-key",
        provider_settings: %{}
      }

      log =
        capture_log(fn ->
          headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
          assert {"Authorization", "Bearer sk-fallback-key"} in headers
        end)

      assert log =~ "deprecated endpoint.api_key"
    end
  end

  describe "lazy on-read promotion" do
    # When an endpoint has integration_uuid=nil but its legacy provider
    # field resolves through PhoenixKit.Integrations, the resolver
    # should write the resolved uuid back to integration_uuid so
    # future requests take the clean uuid path. Best-effort — errors
    # don't block the request.

    test "promotes integration_uuid when provider is a `provider:name` shape that resolves" do
      # Pre-create an integration row.
      {:ok, %{uuid: integration_uuid}} =
        PhoenixKit.Integrations.add_connection("openrouter", "lazy")

      {:ok, _} = PhoenixKit.Integrations.save_setup(integration_uuid, %{"api_key" => "sk-lazy"})

      # Create a real endpoint pinned to that integration via the
      # legacy `provider` string. integration_uuid stays NULL.
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "LazyPromotion-#{System.unique_integer([:positive])}",
          provider: "openrouter:lazy",
          model: "anthropic/claude-3-haiku",
          api_key: "sk-fixture-fallback"
        })

      # First call resolves via the legacy path AND writes back
      # integration_uuid in the background. Reload the endpoint so
      # the fixture's stale `endpoint.integration_uuid = nil` doesn't
      # interfere — we want the resolver to see the saved row's value.
      endpoint = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      headers = OpenRouterClient.build_headers_from_endpoint(endpoint)
      assert {"Authorization", "Bearer sk-lazy"} in headers

      # Endpoint reloaded from DB now has integration_uuid populated.
      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.integration_uuid == integration_uuid
    end

    test "promotes integration_uuid when provider is a uuid string that resolves" do
      {:ok, %{uuid: integration_uuid}} =
        PhoenixKit.Integrations.add_connection("openrouter", "uuid-direct")

      {:ok, _} =
        PhoenixKit.Integrations.save_setup(integration_uuid, %{"api_key" => "sk-direct"})

      # Endpoint stuffed the uuid in the provider string column
      # (pre-V107 form-save shape) instead of using integration_uuid.
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "UuidInProvider-#{System.unique_integer([:positive])}",
          provider: integration_uuid,
          model: "a/b",
          api_key: "sk-fixture-fallback"
        })

      OpenRouterClient.build_headers_from_endpoint(endpoint)

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.integration_uuid == integration_uuid
    end

    test "does NOT promote when integration_uuid is already set" do
      {:ok, %{uuid: integration_uuid}} =
        PhoenixKit.Integrations.add_connection("openrouter", "no-promote")

      {:ok, _} =
        PhoenixKit.Integrations.save_setup(integration_uuid, %{"api_key" => "sk-noop"})

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "AlreadyPinned-#{System.unique_integer([:positive])}",
          provider: "openrouter:no-promote",
          integration_uuid: integration_uuid,
          model: "a/b",
          api_key: "sk-fixture-fallback"
        })

      original_updated_at = endpoint.updated_at

      OpenRouterClient.build_headers_from_endpoint(endpoint)

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      # No write happened — updated_at is unchanged.
      assert reloaded.updated_at == original_updated_at
      assert reloaded.integration_uuid == integration_uuid
    end
  end
end
