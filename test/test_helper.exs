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

Mox.defmock(PhoenixKitAI.Test.RealtimeMock, for: Xai.RealtimeBehaviour)

alias PhoenixKitAI.Test.Repo, as: TestRepo

# Check if the test database exists before trying to connect.
db_config = Application.get_env(:phoenix_kit_ai, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_ai_test"

db_check =
  try do
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
  rescue
    # `psql` not on PATH — System.cmd raises :enoent. Fall through to
    # the connect attempt which will fail-soft and skip integration tests.
    ErlangError -> :try_connect
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

      # Build the schema directly from core's versioned migrations —
      # same call the host app makes in production. Core's V40 creates
      # the `uuid-ossp` / `pgcrypto` extensions + `uuid_generate_v7()`
      # function; V57+ creates the AI tables; V107 adds the
      # `integration_uuid` column + UNIQUE index on `lower(name)` that
      # this module's schema and tests depend on. No module-owned DDL.
      #
      # Standalone runs against Hex `phoenix_kit ~> 1.7` will fail at
      # boot with "column integration_uuid does not exist" if the
      # published Hex version pre-dates V107 — that's expected. The
      # canonical test channel for this module is via
      # `phoenix_kit_parent` (path-dep `override: true` resolves
      # `phoenix_kit` to the local checkout, which has V107). See
      # ~/.claude memory `feedback_run_tests_via_parent.md`.
      #
      # `ensure_current/2` (core 1.7.105+ / phoenix_kit#515) re-applies
      # any newly-shipped Vxxx migrations on every boot by passing a
      # fresh wall-clock version to Ecto.Migrator. Replaces the
      # `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)`
      # pattern, which silently stopped re-applying once `0` was
      # recorded in `schema_migrations` — see
      # `dev_docs/migration_cleanup.md` for the staleness story.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

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

# `PhoenixKit.TaskSupervisor` is the named Task.Supervisor that
# `Task.Supervisor.start_child/2` callsites in the AI module's LVs
# target for fire-and-forget supervised work (validate-then-fetch in
# endpoint_form.ex). Production starts it as part of
# `PhoenixKit.Supervisor`; the test VM only runs the minimal subset
# above, so we boot it explicitly here. Without this, any LV test
# that hits the validation path crashes with `(EXIT) no process` on
# the start_child call.
{:ok, _pid} = Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor)

# `PhoenixKitAI.Realtime.Supervisor` is the DynamicSupervisor that owns
# xAI realtime voice sessions (`PhoenixKitAI.Realtime.Session`), started in
# production via `PhoenixKitAI.children/0` + `PhoenixKit.Supervisor`. Same
# gap as `PhoenixKit.TaskSupervisor` above — boot it explicitly here.
{:ok, _pid} =
  DynamicSupervisor.start_link(name: PhoenixKitAI.Realtime.Supervisor, strategy: :one_for_one)

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
