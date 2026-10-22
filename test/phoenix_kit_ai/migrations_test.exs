defmodule PhoenixKitAI.MigrationsTest do
  @moduledoc """
  The module-owned chain, run as the real SQL inside the sandbox: the table it
  builds, its unique index and checks, a re-run, and a down/up round trip —
  through the statements and through `Ecto.Migrator` with the wrapper a host's
  generated migration uses. Core's own `phoenix_kit_ai_*` tables are never
  touched by it.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Migrations
  alias PhoenixKitAI.Test.SchemaMigration

  @tables ~w(phoenix_kit_ai_model_capabilities)

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
      assert Migrations.current_version() == 1
      assert marker() == "ai_schema:1"
      assert existing_tables() == @tables
      assert Migrations.migrated_version_runtime() == 1
    end

    test "the base URL and model pair is unique; the flags take yes, no or unknown only" do
      assert_structure()
    end

    test "core's AI tables carry no marker of this chain" do
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

      assert marker() == "ai_schema:1"
      assert existing_tables() == @tables
    end

    test "down to 0 drops the module's table, and up builds it again" do
      run(Migrations.down_statements("public", 0))
      assert existing_tables() == []
      assert Migrations.migrated_version_runtime() == 0

      run(Migrations.up_statements("public"))
      assert existing_tables() == @tables
      assert marker() == "ai_schema:1"

      # Built here, from the statements as they are now — not the schema a
      # persistent test database kept from an earlier V1.
      assert_structure()
    end

    test "down does not touch core's AI tables" do
      run(Migrations.down_statements("public", 0))

      assert [[_]] =
               query(
                 "SELECT 1 FROM information_schema.tables WHERE table_name = 'phoenix_kit_ai_endpoints'"
               )
    end

    test "a version the chain does not have is refused in both directions" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("public", 2) end
      assert_raise ArgumentError, fn -> Migrations.down_statements("public", 2) end
    end

    test "an invalid prefix is refused" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("bad prefix; DROP", 1) end
    end

    test "up to 0 applies nothing" do
      assert Migrations.up_statements("public", 0) == []
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
      assert Migrations.migrated_version_runtime() == 1
      assert_structure()
    end
  end

  test "the module names this chain as its migration module" do
    assert PhoenixKitAI.migration_module() == Migrations
  end
end
