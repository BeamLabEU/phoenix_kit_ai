# Test helper for PhoenixKitAI test suite
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable.
#
# To enable integration tests:
#   createdb phoenix_kit_ai_test

# Elixir 1.19's `mix test` no longer auto-loads modules from
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Support
# modules are compiled but not loaded, so explicit `Code.require_file/2`
# calls are needed before `test_helper.exs` references them.
support_dir = Path.expand("support", __DIR__)

# Only `require_file` when the module isn't already compiled-and-loaded
# — otherwise ExUnit's own auto-load emits a "redefining module"
# warning.
[
  {PhoenixKitAI.Test.Repo, "test_repo.ex"},
  {PhoenixKitAI.Test.Layouts, "test_layouts.ex"},
  {PhoenixKitAI.Test.Router, "test_router.ex"},
  {PhoenixKitAI.Test.Endpoint, "test_endpoint.ex"},
  {PhoenixKitAI.ActivityLogAssertions, "activity_log_assertions.ex"},
  {PhoenixKitAI.DataCase, "data_case.ex"},
  {PhoenixKitAI.LiveCase, "live_case.ex"}
]
|> Enum.each(fn {mod, file} ->
  Code.ensure_loaded?(mod) || Code.require_file(file, support_dir)
end)

alias PhoenixKitAI.Test.Repo, as: TestRepo

# Check if the test database exists before trying to connect.
db_config = Application.get_env(:phoenix_kit_ai, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_ai_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests excluded.
       Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # uuid-ossp extension + uuid_generate_v7 (normally provided by
      # core PhoenixKit's V40 migration).
      TestRepo.query!("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

      TestRepo.query!("""
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
        uuid_bytes := unix_ts_ms || gen_random_bytes(10);
        uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
        uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END;
      $$ LANGUAGE plpgsql VOLATILE;
      """)

      # Run the test migrations. `priv: "test/support/postgres"` in
      # config/test.exs points Ecto.Migrator at the right folder.
      Ecto.Migrator.run(TestRepo, :up, all: true)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_ai, :test_repo_available, repo_available)

# Start minimal PhoenixKit services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# Force PhoenixKit's URL prefix cache so `Routes.ai_path/0` produces
# paths that the test router matches. Admin paths always get the
# default locale ("en") prefix, so the test router scopes under
# `/en/admin/ai`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive LiveViews
# via `live/2` with real URLs. Runs with `server: false` so no port is
# opened.
if repo_available do
  {:ok, _} = PhoenixKitAI.Test.Endpoint.start_link()
end

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
