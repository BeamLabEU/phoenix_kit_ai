defmodule PhoenixKitAI.RequestFkConstraintsTest do
  @moduledoc """
  Regression guard for FK violations escaping `Request.changeset/2` as raw
  `Ecto.ConstraintError` (a 500) instead of changeset errors.

  Core names these constraints `fk_ai_requests_*` in its v135 chain, not the
  `phoenix_kit_ai_requests_<field>_fkey` that `foreign_key_constraint/2` derives
  by default, so a declaration without an explicit `:name` never matches.

  `prompt_uuid` was the awkward one: v135 added its FK TWICE under two
  different names, so installs carried one or both. Module chain V7 keeps one,
  `phoenix_kit_ai_requests_prompt_uuid_fkey`, and the changeset declares that
  name alone.
  """
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test-key"
      })

    ep
  end

  defp base_attrs do
    %{status: "success", model: "a/b", input_tokens: 1, output_tokens: 1, total_tokens: 2}
  end

  # The changeset-level guard: a bad reference is a changeset error, never a
  # raised Ecto.ConstraintError (a 500).
  for field <- [:prompt_uuid, :user_uuid, :endpoint_uuid] do
    test "a non-existent #{field} is a changeset error at insert, not a raise" do
      attrs = Map.put(base_attrs(), unquote(field), Ecto.UUID.generate())

      assert {:error, %Ecto.Changeset{} = changeset} =
               %Request{} |> Request.changeset(attrs) |> Repo.insert()

      assert Keyword.has_key?(changeset.errors, unquote(field))
    end
  end

  # The usage log above it: a call that happened is still recorded. The
  # unresolvable reference is left empty and the submitted id is kept, so the
  # row counts toward every cap it can still be attributed to.
  for field <- [:prompt_uuid, :user_uuid, :endpoint_uuid] do
    test "create_request/1 writes the row without a non-existent #{field}" do
      ghost = Ecto.UUID.generate()
      attrs = Map.put(base_attrs(), unquote(field), ghost)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, request} = PhoenixKitAI.create_request(attrs)
          assert Map.fetch!(request, unquote(field)) == nil
          assert request.metadata["unresolved_refs"] == %{to_string(unquote(field)) => ghost}
        end)

      assert log =~ "usage row written without #{unquote(field)}"
    end
  end

  test "an unresolvable reference keeps the ones that do resolve, and the caller's metadata" do
    ep = endpoint_fixture()
    ghost = Ecto.UUID.generate()

    attrs =
      base_attrs()
      |> Map.merge(%{endpoint_uuid: ep.uuid, user_uuid: ghost, metadata: %{"cached" => false}})

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, request} = PhoenixKitAI.create_request(attrs)
      assert request.endpoint_uuid == ep.uuid
      assert request.user_uuid == nil

      assert request.metadata == %{
               "cached" => false,
               "unresolved_refs" => %{"user_uuid" => ghost}
             }
    end)
  end

  test "two unresolvable references are both dropped, not just the first one reported" do
    # Postgres reports only the first broken foreign key per statement.
    user_ghost = Ecto.UUID.generate()
    endpoint_ghost = Ecto.UUID.generate()

    attrs = Map.merge(base_attrs(), %{user_uuid: user_ghost, endpoint_uuid: endpoint_ghost})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, request} = PhoenixKitAI.create_request(attrs)
        assert request.user_uuid == nil
        assert request.endpoint_uuid == nil

        assert request.metadata["unresolved_refs"] == %{
                 "user_uuid" => user_ghost,
                 "endpoint_uuid" => endpoint_ghost
               }
      end)

    refute log =~ "usage row not written"
    assert length(String.split(log, "usage row written without")) == 2
  end

  test "inside a caller's transaction the retry succeeds and the transaction survives" do
    attrs = Map.put(base_attrs(), :user_uuid, Ecto.UUID.generate())

    assert {:ok, count} =
             Repo.transaction(fn ->
               ExUnit.CaptureLog.capture_log(fn ->
                 assert {:ok, _} = PhoenixKitAI.create_request(attrs)
               end)

               Repo.aggregate(Request, :count)
             end)

    assert count == 1
  end

  test "string-keyed attrs are handled the same way" do
    ghost = Ecto.UUID.generate()

    attrs =
      base_attrs()
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("user_uuid", ghost)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{user_uuid: nil, metadata: %{"unresolved_refs" => %{"user_uuid" => ^ghost}}}} =
               PhoenixKitAI.create_request(attrs)
    end)
  end

  test "any other validation failure still fails" do
    attrs = Map.put(base_attrs(), :status, "not-a-status")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, %Ecto.Changeset{} = changeset} = PhoenixKitAI.create_request(attrs)
      assert Keyword.has_key?(changeset.errors, :status)
    end)
  end

  test "a valid endpoint reference still inserts" do
    ep = endpoint_fixture()
    attrs = Map.put(base_attrs(), :endpoint_uuid, ep.uuid)

    assert {:ok, request} = PhoenixKitAI.create_request(attrs)
    assert request.endpoint_uuid == ep.uuid
  end

  test "prompt_uuid declares the one constraint name module chain V7 keeps" do
    names =
      %Request{}
      |> Request.changeset(base_attrs())
      |> Map.fetch!(:constraints)
      |> Enum.filter(&(&1.field == :prompt_uuid))
      |> Enum.map(& &1.constraint)

    assert names == [PhoenixKitAI.Migrations.prompt_fk()]
  end

  test "the database under test carries exactly that one key on prompt_uuid" do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conname FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(c.conkey)
      WHERE c.contype = 'f' AND t.relname = 'phoenix_kit_ai_requests'
        AND n.nspname = 'public' AND a.attname = 'prompt_uuid'
      """)

    assert rows == [[PhoenixKitAI.Migrations.prompt_fk()]]
  end

  test "every belongs_to on the schema declares a foreign key constraint" do
    declared =
      %Request{}
      |> Request.changeset(base_attrs())
      |> Map.fetch!(:constraints)
      |> Enum.filter(&(&1.type == :foreign_key))
      |> MapSet.new(& &1.field)

    associated =
      Request.__schema__(:associations)
      |> Enum.map(&Request.__schema__(:association, &1))
      |> Enum.filter(&match?(%Ecto.Association.BelongsTo{}, &1))
      |> MapSet.new(& &1.owner_key)

    missing = MapSet.difference(associated, declared)

    assert MapSet.equal?(missing, MapSet.new()),
           """
           These belongs_to keys have no foreign_key_constraint: #{inspect(MapSet.to_list(missing))}

           Without one, a violation raises Ecto.ConstraintError instead of
           returning a changeset error. Declare it with the name core's migration
           actually creates (`fk_ai_requests_<field>`), not the Ecto default.
           """
  end
end
