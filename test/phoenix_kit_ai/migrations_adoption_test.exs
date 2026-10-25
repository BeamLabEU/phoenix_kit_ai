defmodule PhoenixKitAI.MigrationsAdoptionTest do
  @moduledoc """
  V5 adopts the three tables core's chain created for this module. The SQL is
  data, so the properties that matter can be checked without a database: the
  adoption comes before the first statement that touches those tables, every
  statement is guarded, and nothing in it or in `down/1` destroys rows.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitAI.Migrations

  @adopted ~w(phoenix_kit_ai_endpoints phoenix_kit_ai_prompts phoenix_kit_ai_requests)

  defp index_of(statements, fun), do: Enum.find_index(statements, fun)

  test "the chain is V5" do
    assert Migrations.current_version() == 5
  end

  test "each adopted table is created IF NOT EXISTS" do
    statements = Migrations.up_statements("public")

    for table <- @adopted do
      assert Enum.any?(
               statements,
               &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
             ),
             "#{table} is not adopted"
    end
  end

  test "the adopted requests table has the V223 cost column V4 waits for" do
    create =
      Enum.find(
        Migrations.up_statements("public"),
        &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.phoenix_kit_ai_requests (")
      )

    assert create =~ "\"cost\" numeric(28,18)"
  end

  test "the adoption comes before the first statement that touches an adopted table" do
    statements = Migrations.up_statements("public")

    last_create =
      statements
      |> Enum.with_index()
      |> Enum.filter(fn {s, _} ->
        Enum.any?(@adopted, &String.contains?(s, "CREATE TABLE IF NOT EXISTS public.#{&1} ("))
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.max()

    # V2's guard-events table references endpoints and requests; V4 reads `cost`.
    v2 = index_of(statements, &String.contains?(&1, "phoenix_kit_ai_task_settings ("))
    v4 = index_of(statements, &String.contains?(&1, "phoenix_kit_ai V4 needs core"))

    assert last_create < v2
    assert last_create < v4
  end

  test "every constraint and index of the adoption is guarded" do
    adoption =
      Migrations.up_statements("public")
      |> Enum.filter(
        &String.contains?(&1, ["ADD CONSTRAINT phoenix_kit_ai_", "ADD CONSTRAINT fk_ai_"])
      )

    assert length(adoption) >= 6
    assert Enum.all?(adoption, &String.contains?(&1, "IF NOT EXISTS"))
  end

  test "a target below 5 builds the chain as it was, without the adoption" do
    for target <- 1..4 do
      refute Enum.any?(
               Migrations.up_statements("public", target),
               &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.phoenix_kit_ai_endpoints")
             )
    end
  end

  test "the schema prefix reaches the adopted objects" do
    statements = Migrations.up_statements("tenant_a")

    assert Enum.any?(
             statements,
             &String.contains?(
               &1,
               "CREATE TABLE IF NOT EXISTS tenant_a.phoenix_kit_ai_endpoints ("
             )
           )

    assert Enum.any?(statements, &String.contains?(&1, "tenant_a.uuid_generate_v7()"))
    refute Enum.any?(statements, &String.contains?(&1, "public.phoenix_kit_ai_endpoints"))
  end

  test "down from V5 only rewrites the marker, and nothing drops an adopted table" do
    assert [marker] = Migrations.down_statements("public", 4)
    assert marker =~ "ai_schema:4"

    for target <- 0..4, statement <- Migrations.down_statements("public", target) do
      refute Enum.any?(@adopted, &(statement =~ ~r/DROP TABLE[^;]*#{&1}/))
    end
  end
end
