# Test helper for PhoenixKitAI test suite
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests need a real PostgreSQL database — most of the
#          suite (~550 of ~910 tests), since `PhoenixKitAI.DataCase` and
#          `PhoenixKitAI.LiveCase` both tag every test they template
#          `:integration`.
#
# `mix test` provisions its own database automatically: the `test:` alias
# in mix.exs runs `ecto.create --quiet` first, same contract as any
# standard Phoenix app. If the database is still unusable after that —
# unreachable host, wrong credentials, migrations that fail — THIS FILE
# MUST ABORT THE RUN with a nonzero exit. It must NOT print a warning and
# quietly exclude the `:integration` tag: that turns "the database is
# broken" into "358 tests, 0 failures" and nobody notices for months (see
# the incident this rewrite fixes — the old fail-soft below caught every
# exception/exit from a dead connection pool, downgraded it to a `false`
# flag, and dropped 551 tests while reporting success).
#
# The ONLY sanctioned way to run without a database is the explicit,
# off-by-default opt-in below:
#
#   PK_AI_SKIP_DB=1 mix test
#
# for a contributor machine that genuinely has no Postgres and only wants
# the ~360 pure-unit tests. CI and the standard local/precommit workflow
# must never set this — a database failure there means something is
# actually broken and the run should go red.

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

db_config = Application.get_env(:phoenix_kit_ai, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_ai_test"

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to a direct connection attempt below.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(db_config) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

skip_db? = System.get_env("PK_AI_SKIP_DB") in ["1", "true"]

repo_available =
  cond do
    skip_db? ->
      IO.puts("""
      \n⚠  PK_AI_SKIP_DB=1 — skipping database "#{db_name}", excluding :integration tests.
         This is a manual opt-out for a contributor machine with no Postgres.
         `mix test` normally creates its own database (see the `test:` alias
         in mix.exs), so do NOT set this in CI or the standard/precommit
         workflow: a database failure there is a real problem, not something
         to route around silently.
      """)

      false

    db_check == :not_found ->
      # The preflight above already printed a classified diagnostic to
      # stderr (bad role, missing database, unreachable host, ...). Per the
      # module doc at the top of this file, that is a real infrastructure
      # problem once `mix test` has already tried to provision the database
      # — not something to downgrade to a warning and 358 quietly-passing
      # tests. The only sanctioned way around this is PK_AI_SKIP_DB=1 above.
      raise """
      Cannot reach test database "#{db_name}" — see the preflight diagnostic above.
      Set PK_AI_SKIP_DB=1 to run only the unit tests on a machine with no Postgres.
      """

    true ->
      # Deliberately unguarded — no rescue, no catch. An unusable database
      # (missing, unreachable, wrong role, migrations that fail) must crash
      # test_helper.exs here with a nonzero exit and Postgrex's own error
      # in the log, not get caught and silently downgraded to "exclude
      # :integration". See the module doc above for why.
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. Core's V40 creates the
      # `uuid-ossp` / `pgcrypto` extensions + `uuid_generate_v7()` function;
      # V57+ creates the AI tables; V107 adds the `integration_uuid` column
      # + UNIQUE index on `lower(name)` that this module's schema and tests
      # depend on. No module-owned DDL.
      #
      # Standalone runs against Hex `phoenix_kit ~> 1.7` will fail at boot
      # with "column integration_uuid does not exist" if the published Hex
      # version pre-dates V107 — that's expected. The canonical test channel
      # for this module is via `phoenix_kit_parent` (path-dep
      # `override: true` resolves `phoenix_kit` to the local checkout,
      # which has V107). See ~/.claude memory
      # `feedback_run_tests_via_parent.md`.
      #
      # `ensure_current/2` (core 1.7.105+ / phoenix_kit#515) re-applies any
      # newly-shipped Vxxx migrations on every boot by passing a fresh
      # wall-clock version to Ecto.Migrator. Replaces the
      # `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)`
      # pattern, which silently stopped re-applying once `0` was recorded in
      # `schema_migrations` — see `dev_docs/migration_cleanup.md` for the
      # staleness story.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
  end

Application.put_env(:phoenix_kit_ai, :test_repo_available, repo_available)

# Start minimal PhoenixKit services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

case PhoenixKitAI.RequestCache.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# `PhoenixKit.Test.Fixtures.user_fixture/1` and friends register through
# `PhoenixKit.Users.Auth.register_user/2`, which calls the Hammer-backed rate
# limiter — without this its ETS table does not exist and the fixture dies with
# "the table identifier does not refer to an existing ETS table". Mirrors core's
# own test_helper and the same lines in billing, calendar, ecommerce, projects
# and staff.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

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
# opened. Only meaningful when the repo is actually up — under
# PK_AI_SKIP_DB every LiveView test is excluded via :integration anyway.
if repo_available do
  {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PhoenixKitAI.Test.PubSub)
  {:ok, _} = PhoenixKitAI.Test.Endpoint.start_link()
end

# The `gettext_backend` / `gettext_domain` Tab API (PhoenixKit core PR #522)
# is what makes admin_tabs/0's per-module i18n wiring render translated —
# `Tab.localized_label/1` doesn't exist before it. This module's `phoenix_kit`
# floor (~> 2.0) is well past that release, so this is normally a formality,
# but it keeps CI green if a consumer ever resolves an older pin.
#
# This one stays a genuine capability probe, not a fail-soft: it keys on
# `function_exported?/3` at compile-resolved-dependency time, which never
# raises and never depends on the database, so there is nothing here to
# swallow.
i18n_api_available =
  Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
    function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1)

unless i18n_api_available do
  require Logger

  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )
end

# Exclude :integration only under the explicit PK_AI_SKIP_DB opt-out above
# — never as a side effect of the database being broken.
exclude =
  [
    if(skip_db?, do: :integration),
    if(!i18n_api_available, do: :requires_phoenix_kit_i18n_api)
  ]
  |> Enum.reject(&is_nil/1)

ExUnit.start(exclude: exclude)
