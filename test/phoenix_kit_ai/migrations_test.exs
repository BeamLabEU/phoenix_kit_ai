defmodule PhoenixKitAI.MigrationsTest do
  @moduledoc """
  The module-owned chain, run as the real SQL inside the sandbox: the table it
  builds, its unique index and checks, a re-run, and a down/up round trip —
  through the statements and through `Ecto.Migrator` with the wrapper a host's
  generated migration uses. Core's own `phoenix_kit_ai_*` tables are never
  touched by it.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.Migrations
  alias PhoenixKitAI.Test.SchemaMigration

  @v1_tables ~w(phoenix_kit_ai_model_capabilities)
  @v2_tables ~w(phoenix_kit_ai_guard_events phoenix_kit_ai_model_capabilities phoenix_kit_ai_task_settings phoenix_kit_ai_task_user_limits)
  @tables ~w(phoenix_kit_ai_guard_blocks phoenix_kit_ai_guard_events phoenix_kit_ai_model_capabilities phoenix_kit_ai_task_settings phoenix_kit_ai_task_user_limits)
  @task_index "phoenix_kit_ai_requests_task_inserted_at_index"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp existing_tables do
    query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ANY($1) ORDER BY 1",
      [@tables]
    )
    |> List.flatten()
  end

  defp marker do
    case query("SELECT obj_description('public.phoenix_kit_ai_model_capabilities'::regclass)") do
      [[marker]] -> marker
    end
  end

  defp indexdef(name) do
    [[indexdef]] = query("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name])
    indexdef
  end

  defp index_names do
    query("SELECT indexname FROM pg_indexes WHERE indexname = $1", [@task_index])
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  defp user_uuid, do: Fixtures.user_fixture().uuid

  defp endpoint_uuid do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Migrations EP #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test"
      })

    endpoint.uuid
  end

  defp flag_columns do
    query(
      "SELECT column_name, column_default, is_nullable FROM information_schema.columns WHERE table_name = 'phoenix_kit_ai_model_capabilities' AND column_name IN ('file_input', 'image_output') ORDER BY 1"
    )
  end

  defp assert_v2_flags do
    assert [
             ["file_input", "'unknown'::character varying", "NO"],
             ["image_output", "'unknown'::character varying", "NO"]
           ] = flag_columns()

    model = "m-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Repo.query(
               "INSERT INTO phoenix_kit_ai_model_capabilities (base_url, model, fetched_at) VALUES ('https://f.test/v1', $1, now())",
               [model]
             )

    assert [["unknown", "unknown"]] =
             query(
               "SELECT file_input, image_output FROM phoenix_kit_ai_model_capabilities WHERE base_url = 'https://f.test/v1' AND model = $1",
               [model]
             )

    for flag <- ~w(file_input image_output) do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO phoenix_kit_ai_model_capabilities (base_url, model, fetched_at, #{flag}) VALUES ('https://f.test/v1', $1, now(), 'maybe')",
                 [flag]
               )
    end
  end

  defp insert_event(kind, dedupe_key) do
    Repo.query(
      "INSERT INTO phoenix_kit_ai_guard_events (kind, task_key, dedupe_key) VALUES ($1, 't', $2)",
      [kind, dedupe_key]
    )
  end

  # The V2 objects as the database has them now.
  defp assert_v2_structure do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert_event("something_else", nil)

    for kind <-
          ~w(model_unfit limit_warning limit_reached limit_forgiven off_purpose off_purpose_signal anomaly blocked unblocked) do
      assert {:ok, _} = insert_event(kind, nil)
    end

    assert {:ok, _} = insert_event("limit_reached", "k-#{System.unique_integer([:positive])}")
    assert {:ok, _} = insert_event("limit_reached", "dup")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert_event("limit_reached", "dup")

    assert indexdef("phoenix_kit_ai_guard_events_dedupe_key_index") =~
             "WHERE (dedupe_key IS NOT NULL)"

    assert indexdef("phoenix_kit_ai_task_settings_task_key_index") =~ "UNIQUE"

    assert indexdef("phoenix_kit_ai_task_user_limits_task_key_user_uuid_index") =~
             "(task_key, user_uuid)"

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "INSERT INTO phoenix_kit_ai_task_settings (task_key, guard_mode) VALUES ('m', 'loud')"
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "INSERT INTO phoenix_kit_ai_guard_events (kind, task_key, reason) VALUES ('anomaly', 't', $1)",
               [String.duplicate("x", 501)]
             )
  end

  defp insert_block(group, user) do
    Repo.query(
      "INSERT INTO phoenix_kit_ai_guard_blocks (block_group, user_uuid) VALUES ($1, $2)",
      [group, dump(user)]
    )
  end

  # The V3 objects as the database has them now.
  defp assert_v3_structure do
    user = user_uuid()

    assert indexdef("phoenix_kit_ai_guard_blocks_active_index") =~ "UNIQUE"

    assert indexdef("phoenix_kit_ai_guard_blocks_active_index") =~
             "(block_group, user_uuid) WHERE (lifted_at IS NULL)"

    assert {:ok, _} = insert_block("free_text", user)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert_block("free_text", user)

    # Another group of the same user, and a lifted block next to the active one.
    assert {:ok, _} = insert_block("test.other", user)

    query(
      "UPDATE phoenix_kit_ai_guard_blocks SET lifted_at = now() WHERE block_group = 'free_text'"
    )

    assert {:ok, _} = insert_block("free_text", user)

    assert [[false, %NaiveDateTime{}]] =
             query(
               "SELECT private, blocked_at FROM phoenix_kit_ai_guard_blocks WHERE block_group = 'test.other'"
             )

    for column <- ~w(reason lift_note) do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO phoenix_kit_ai_guard_blocks (block_group, user_uuid, #{column}) VALUES ('g-#{column}', $1, $2)",
                 [dump(user), String.duplicate("x", 501)]
               )
    end

    for {column, value} <- [{"block_group", nil}, {"user_uuid", nil}] do
      assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
               Repo.query(
                 "INSERT INTO phoenix_kit_ai_guard_blocks (block_group, user_uuid) VALUES ($1, $2)",
                 if(column == "block_group", do: [value, dump(user)], else: ["g", value])
               )
    end
  end

  defp insert_row(values) do
    Repo.query(
      "INSERT INTO phoenix_kit_ai_model_capabilities (base_url, model, vision, tools, json_schema, json, fetched_at) VALUES ($1, $2, $3, $4, $5, $6, now())",
      values
    )
  end

  # The unique pair and the yes/no/unknown checks, as the database has them now.
  defp assert_structure do
    index = indexdef("phoenix_kit_ai_model_capabilities_base_url_model_index")
    assert index =~ "UNIQUE"
    assert index =~ "(base_url, model)"

    assert {:ok, _} = insert_row(["https://x.test/v1", "m", "yes", "no", "unknown", "yes"])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert_row(["https://x.test/v1", "m", "yes", "no", "unknown", "yes"])

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert_row(["https://x.test/v1", "other", "maybe", "no", "unknown", "yes"])
  end

  describe "the chain as built at boot" do
    test "is at the current version, with its table" do
      assert Migrations.current_version() == 5
      assert marker() == "ai_schema:5"
      assert existing_tables() == @tables
      assert Migrations.migrated_version_runtime() == 5
    end

    test "the base URL and model pair is unique; the flags take yes, no or unknown only" do
      assert_structure()
    end

    test "the adopted tables carry no marker of their own (it sits on the capability table)" do
      for table <- ~w(phoenix_kit_ai_endpoints phoenix_kit_ai_prompts phoenix_kit_ai_requests) do
        [[comment]] = query("SELECT obj_description($1::text::regclass)", ["public.#{table}"])
        refute is_binary(comment) and String.starts_with?(comment, "ai_schema:")
      end
    end
  end

  describe "up_statements/2 and down_statements/2" do
    test "a second up changes nothing and does not fail" do
      run(Migrations.up_statements("public"))
      run(Migrations.up_statements("public"))

      assert marker() == "ai_schema:5"
      assert existing_tables() == @tables
    end

    test "down to 0 drops the module's table, and up builds it again" do
      run(Migrations.down_statements("public", 0))
      assert existing_tables() == []
      assert index_names() == []
      assert Migrations.migrated_version_runtime() == 0

      run(Migrations.up_statements("public"))
      assert existing_tables() == @tables
      assert marker() == "ai_schema:5"

      # Built here, from the statements as they are now — not the schema a
      # persistent test database kept from an earlier V1.
      assert_structure()
      assert_v2_structure()
      assert_v3_structure()
    end

    test "down does not touch core's AI tables" do
      run(Migrations.down_statements("public", 0))

      assert [[_]] =
               query(
                 "SELECT 1 FROM information_schema.tables WHERE table_name = 'phoenix_kit_ai_endpoints'"
               )
    end

    test "a version the chain does not have is refused in both directions" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("public", 6) end
      assert_raise ArgumentError, fn -> Migrations.down_statements("public", 6) end
    end

    test "an invalid prefix is refused" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("bad prefix; DROP", 1) end
    end

    test "up to 0 applies nothing" do
      assert Migrations.up_statements("public", 0) == []
    end
  end

  describe "V2: task settings, personal limits, guard events, the task index" do
    test "the guard event kinds are checked, a dedupe key is unique, and NULL keys repeat" do
      assert_v2_structure()
    end

    test "deleting a user removes its personal limits and its events; the actor and endpoint are cleared" do
      user = user_uuid()
      actor = user_uuid()
      endpoint = endpoint_uuid()

      query(
        "INSERT INTO phoenix_kit_ai_task_user_limits (task_key, user_uuid, limits) VALUES ('t', $1, '{}')",
        [dump(user)]
      )

      query(
        "INSERT INTO phoenix_kit_ai_guard_events (kind, task_key, user_uuid, endpoint_uuid, actor_uuid) VALUES ('limit_forgiven', 't', $1, $2, $3), ('model_unfit', 't', NULL, $2, $3)",
        [dump(user), dump(endpoint), dump(actor)]
      )

      query(
        "INSERT INTO phoenix_kit_ai_task_settings (task_key, updated_by_uuid, classifier_endpoint_uuid) VALUES ('t', $1, $2)",
        [dump(actor), dump(endpoint)]
      )

      query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [dump(user)])
      assert query("SELECT count(*) FROM phoenix_kit_ai_task_user_limits") == [[0]]
      assert query("SELECT kind FROM phoenix_kit_ai_guard_events") == [["model_unfit"]]

      query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [dump(actor)])
      query("DELETE FROM phoenix_kit_ai_endpoints WHERE uuid = $1", [dump(endpoint)])

      assert query("SELECT actor_uuid, endpoint_uuid FROM phoenix_kit_ai_guard_events") == [
               [nil, nil]
             ]

      assert query(
               "SELECT updated_by_uuid, classifier_endpoint_uuid FROM phoenix_kit_ai_task_settings"
             ) == [[nil, nil]]
    end

    test "the capability snapshot gets file_input and image_output, unknown by default and checked" do
      assert_v2_flags()

      run(Migrations.down_statements("public", 1))
      assert flag_columns() == []
      run(Migrations.up_statements("public"))
      assert_v2_flags()
    end

    test "the journal gets an index on the task and the time, with no status condition" do
      index = indexdef(@task_index)
      assert index =~ "phoenix_kit_ai_requests"
      assert index =~ "((metadata ->> 'task'::text)), inserted_at"
      refute index =~ "WHERE"
    end

    test "down to 1 removes what V2 added and keeps V1; up again restores it" do
      run(Migrations.down_statements("public", 1))
      assert existing_tables() == @v1_tables
      assert index_names() == []
      assert marker() == "ai_schema:1"
      assert Migrations.migrated_version_runtime() == 1

      run(Migrations.up_statements("public"))
      assert existing_tables() == @tables
      assert marker() == "ai_schema:5"
      assert_v2_structure()
    end
  end

  describe "V3: blocks" do
    test "one active block per group and user; reason and note at most 500; both keys required" do
      assert_v3_structure()
    end

    test "the guard event kinds already include the off-purpose, anomaly and block kinds" do
      for kind <- ~w(off_purpose off_purpose_signal anomaly blocked unblocked) do
        assert {:ok, _} = insert_event(kind, nil)
      end
    end

    test "deleting the user removes the block; the event, blocker and lifter are cleared" do
      user = user_uuid()
      blocked_by = user_uuid()
      lifted_by = user_uuid()

      [[event]] =
        query(
          "INSERT INTO phoenix_kit_ai_guard_events (kind, task_key) VALUES ('off_purpose', 't') RETURNING uuid"
        )

      query(
        "INSERT INTO phoenix_kit_ai_guard_blocks (block_group, user_uuid, origin_event_uuid, blocked_by_uuid, lifted_by_uuid, lifted_at) VALUES ('g', $1, $2, $3, $4, now()), ('g2', $5, $2, $3, NULL, NULL)",
        [dump(user), event, dump(blocked_by), dump(lifted_by), dump(blocked_by)]
      )

      query("DELETE FROM phoenix_kit_ai_guard_events WHERE uuid = $1", [event])
      query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [dump(lifted_by)])

      assert query(
               "SELECT origin_event_uuid, lifted_by_uuid FROM phoenix_kit_ai_guard_blocks WHERE block_group = 'g'"
             ) == [[nil, nil]]

      query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [dump(blocked_by)])

      # The blocker's own block went with them; the other keeps its row.
      assert query("SELECT block_group, blocked_by_uuid FROM phoenix_kit_ai_guard_blocks") == [
               ["g", nil]
             ]

      query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [dump(user)])
      assert query("SELECT count(*) FROM phoenix_kit_ai_guard_blocks") == [[0]]
    end

    test "down to 2 removes the blocks and keeps V2; up again restores them" do
      run(Migrations.down_statements("public", 2))
      assert existing_tables() == @v2_tables
      assert marker() == "ai_schema:2"
      assert Migrations.migrated_version_runtime() == 2

      run(Migrations.up_statements("public"))
      assert existing_tables() == @tables
      assert marker() == "ai_schema:5"
      assert_v3_structure()
    end
  end

  describe "V4: money in dollars" do
    @cap_keys ~w(ai_daily_cap ai_daily_cap_per_endpoint ai_daily_cap_per_user)

    defp put_setting(key, value) do
      query(
        "INSERT INTO public.phoenix_kit_settings (key, value, module) VALUES ($1, $2, 'ai') " <>
          "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        [key, value]
      )
    end

    defp setting(key) do
      case query("SELECT value FROM public.phoenix_kit_settings WHERE key = $1", [key]) do
        [[value]] -> value
        [] -> nil
      end
    end

    defp clear_caps do
      query("DELETE FROM public.phoenix_kit_settings WHERE key = ANY($1)", [
        @cap_keys ++ ~w(ai_daily_budget ai_daily_budget_per_endpoint ai_daily_budget_per_user)
      ])
    end

    defp limits(table, uuid) do
      [[limits]] = query("SELECT limits FROM public.#{table} WHERE uuid = $1", [dump(uuid)])
      limits
    end

    defp pricing(endpoint_uuid) do
      [[settings]] =
        query("SELECT provider_settings FROM public.phoenix_kit_ai_endpoints WHERE uuid = $1", [
          dump(endpoint_uuid)
        ])

      settings["pricing"]
    end

    # The released shapes: caps as digit strings in millionths, money cells and
    # prices as JSON numbers in millionths.
    defp seed_released do
      clear_caps()
      put_setting("ai_daily_budget", "5000000")
      put_setting("ai_daily_budget_per_endpoint", " 250000 ")
      put_setting("ai_daily_budget_per_user", "0")

      setting =
        Repo.insert!(%PhoenixKitAI.TaskSetting{
          task_key: "test.v4.#{System.unique_integer([:positive])}",
          limits: %{
            "task" => %{
              "money" => %{"day" => 1_500_000, "month" => "2500000"},
              "requests" => %{"day" => 5}
            },
            "user" => %{"money" => %{"day" => "2.50"}}
          }
        })

      personal =
        Repo.insert!(%PhoenixKitAI.TaskUserLimit{
          task_key: setting.task_key,
          user_uuid: user_uuid(),
          limits: %{
            "money" => %{"month" => 20_000_000, "day" => "0.75"},
            "tokens" => %{"day" => 100}
          }
        })

      endpoint = endpoint_uuid()

      query(
        "UPDATE public.phoenix_kit_ai_endpoints SET provider_settings = $1 WHERE uuid = $2",
        [
          %{"pricing" => %{"model" => "a/b", "input" => 600_000, "output" => 2_200_000}},
          dump(endpoint)
        ]
      )

      %{setting: setting.uuid, personal: personal.uuid, endpoint: endpoint}
    end

    defp assert_converted(%{setting: setting, personal: personal, endpoint: endpoint}) do
      assert setting("ai_daily_cap") == "5.00"
      assert setting("ai_daily_cap_per_endpoint") == "0.25"
      assert setting("ai_daily_cap_per_user") == "0.00"
      # the released keys are left as they were
      assert setting("ai_daily_budget") == "5000000"
      assert setting("ai_daily_budget_per_endpoint") == " 250000 "

      assert limits("phoenix_kit_ai_task_settings", setting) == %{
               "task" => %{
                 "money" => %{"day" => "1.50", "month" => "2.50"},
                 "requests" => %{"day" => 5}
               },
               "user" => %{"money" => %{"day" => "2.50"}}
             }

      assert limits("phoenix_kit_ai_task_user_limits", personal) == %{
               "money" => %{"month" => "20.00", "day" => "0.75"},
               "tokens" => %{"day" => 100}
             }

      assert pricing(endpoint) == %{"model" => "a/b", "input" => "0.60", "output" => "2.20"}
    end

    test "converts the released millionths to dollar strings; a re-run converts nothing twice" do
      seeded = seed_released()

      run(Migrations.up_statements("public"))
      assert_converted(seeded)
      assert marker() == "ai_schema:5"

      run(Migrations.up_statements("public"))
      assert_converted(seeded)
    end

    test "a cap the new key already holds is kept; a garbage old cap is not copied" do
      clear_caps()
      put_setting("ai_daily_budget", "5000000")
      put_setting("ai_daily_cap", "7.50")
      put_setting("ai_daily_budget_per_endpoint", "lots")

      run(Migrations.up_statements("public"))

      assert setting("ai_daily_cap") == "7.50"
      assert setting("ai_daily_cap_per_endpoint") == nil
      assert setting("ai_daily_cap_per_user") == nil
    end

    test "the converted values read as the same money in the module" do
      seeded = seed_released()
      run(Migrations.up_statements("public"))
      PhoenixKit.Cache.clear(:settings)

      assert Decimal.equal?(PhoenixKitAI.Budget.limit(:global), 5)
      assert Decimal.equal?(PhoenixKitAI.Budget.limit(:endpoint), Decimal.new("0.25"))

      assert %{task: %{money: %{day: day}}} =
               PhoenixKitAI.TaskLimits.normalize_scoped(
                 limits("phoenix_kit_ai_task_settings", seeded.setting)
               )

      assert Decimal.equal?(day, Decimal.new("1.5"))
    end

    test "down to 3 turns them back into millionths and deletes the new keys; up again" do
      seeded = seed_released()
      run(Migrations.up_statements("public"))

      run(Migrations.down_statements("public", 3))
      assert marker() == "ai_schema:3"
      for key <- @cap_keys, do: assert(setting(key) == nil)
      assert setting("ai_daily_budget") == "5000000"

      assert %{
               "task" => %{"money" => %{"day" => 1_500_000, "month" => 2_500_000}},
               "user" => %{"money" => %{"day" => 2_500_000}}
             } = limits("phoenix_kit_ai_task_settings", seeded.setting)

      assert %{"money" => %{"month" => 20_000_000, "day" => 750_000}} =
               limits("phoenix_kit_ai_task_user_limits", seeded.personal)

      assert %{"input" => 600_000, "output" => 2_200_000} = pricing(seeded.endpoint)

      run(Migrations.up_statements("public"))
      assert marker() == "ai_schema:5"
      assert setting("ai_daily_cap") == "5.00"

      assert %{"task" => %{"money" => %{"day" => "1.50"}}} =
               limits("phoenix_kit_ai_task_settings", seeded.setting)

      assert %{"input" => "0.60", "output" => "2.20"} = pricing(seeded.endpoint)
    end
  end

  describe "through Ecto.Migrator, as a host's generated migration runs it" do
    # The sandbox owns the one connection the test may use; the migrator's lock
    # would want a second one. The version is past every version core's chain
    # recorded, so the migrator does not warn about running an older one.
    @migrator_opts [log: false, migration_lock: false]

    test "down then up again" do
      version = 9_000_000_000_000_000 + System.unique_integer([:positive])

      assert :ok = Ecto.Migrator.up(Repo, version, SchemaMigration, @migrator_opts)
      assert :ok = Ecto.Migrator.down(Repo, version, SchemaMigration, @migrator_opts)
      assert existing_tables() == []
      assert Migrations.migrated_version_runtime() == 0

      assert :ok = Ecto.Migrator.up(Repo, version, SchemaMigration, @migrator_opts)
      assert existing_tables() == @tables
      assert Migrations.migrated_version_runtime() == 5
      assert_structure()
      assert_v2_structure()
      assert_v3_structure()
    end
  end

  test "the module names this chain as its migration module" do
    assert PhoenixKitAI.migration_module() == Migrations
  end
end
