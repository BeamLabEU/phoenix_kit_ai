import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_ai_test
config :phoenix_kit_ai, ecto_repos: [PhoenixKitAI.Test.Repo]

# `PGDATABASE` lets this suite point at a database the test role isn't
# allowed to CREATE (e.g. a shared instance) instead of the name Hex CI
# provisions for itself. Same mechanism as core phoenix_kit's
# config/test.exs — see there for the full rationale. Left unset (CI's
# case), this falls back to the previous hardcoded name, so publishing
# and CI are unaffected.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_ai_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

# `PGPOOL` bounds the connection pool the same way core does — the default
# (`schedulers_online() * 2`) opens dozens of connections on a many-core
# box, which is fine against a private local Postgres but not against a
# shared instance already near its connection ceiling.
pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_ai, PhoenixKitAI.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitAI.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_ai` has no endpoint of
# its own in production — the host app provides one — so this tiny
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_ai, PhoenixKitAI.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "ai-test-salt"],
  # LiveView uploads (the playground's image card) need the endpoint's
  # PubSub; started in test_helper.exs.
  pubsub_server: PhoenixKitAI.Test.PubSub,
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitAI.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
