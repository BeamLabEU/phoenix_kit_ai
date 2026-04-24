import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_ai_test
config :phoenix_kit_ai, ecto_repos: [PhoenixKitAI.Test.Repo]

config :phoenix_kit_ai, PhoenixKitAI.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_ai_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/postgres"

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitAI.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_ai` has no endpoint of
# its own in production — the host app provides one — so this tiny
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_ai, PhoenixKitAI.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "ai-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitAI.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
