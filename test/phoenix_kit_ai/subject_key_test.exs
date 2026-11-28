defmodule PhoenixKitAI.SubjectKeyTest do
  @moduledoc """
  `subject_key` on the usage journal (module chain V7): who asked when it is
  not a PhoenixKit user. A verb's `subject_key:` lands on every row the call
  writes and selects the per-user spend caps when there is no user; a
  `user_uuid:` that names no user is kept as the row's subject instead of
  costing the row.
  """

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Budget, Request, RequestCache}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    reset()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      reset()
    end)

    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Subject-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    {:ok, endpoint: ep}
  end

  defp reset do
    RequestCache.clear()
    Budget.reset_warnings()

    for scope <- [:global, :global_month, :endpoint, :user, :user_calls],
        do: {:ok, _} = Budget.set_limit(scope, 0)
  end

  defp stub_chat(cost \\ 0.5) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => cost}
      })
    end)
  end

  defp rows(ep),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid, order_by: r.uuid))

  defp base_attrs,
    do: %{status: "success", model: "a/b", input_tokens: 1, output_tokens: 1, total_tokens: 2}

  describe "Request.subject_key/1" do
    test "trims, turns integers and atoms into strings, and reads blanks as none" do
      assert Request.subject_key("  visitor-1 ") == "visitor-1"
      assert Request.subject_key(42) == "42"
      assert Request.subject_key(:api) == "api"
      assert Request.subject_key("   ") == nil
      assert Request.subject_key(nil) == nil
      assert Request.subject_key(true) == nil
      assert Request.subject_key(%{}) == nil
      assert Request.subject_key("a\0b") == "ab"
    end

    test "a key longer than the column is a digest of the whole key, never a cut" do
      long_a = String.duplicate("x", 300) <> "a"
      long_b = String.duplicate("x", 300) <> "b"

      assert "sha256:" <> hex = Request.subject_key(long_a)
      assert byte_size(hex) == 64
      refute Request.subject_key(long_a) == Request.subject_key(long_b)
      assert Request.subject_key(String.duplicate("y", 255)) == String.duplicate("y", 255)
    end
  end

  describe "create_request/1" do
    test "a key of 255 graphemes but more code points is hashed, and the row is kept" do
      combining = String.duplicate("e\u0301", 255)
      assert "sha256:" <> _ = Request.subject_key(combining)

      assert {:ok, row} =
               PhoenixKitAI.create_request(Map.put(base_attrs(), :subject_key, combining))

      assert "sha256:" <> _ = row.subject_key
    end

    test "stores a subject key" do
      assert {:ok, row} = PhoenixKitAI.create_request(Map.put(base_attrs(), :subject_key, 7))
      assert row.subject_key == "7"
      assert TestRepo.get!(Request, row.uuid).subject_key == "7"
    end

    test "a user_uuid that is not a uuid is the row's subject instead of costing the row" do
      assert {:ok, row} =
               PhoenixKitAI.create_request(Map.put(base_attrs(), :user_uuid, "visitor-9"))

      assert row.user_uuid == nil
      assert row.subject_key == "visitor-9"
      assert row.metadata["unresolved_refs"] == %{"user_uuid" => "visitor-9"}
    end

    test "a uuid of no user becomes the subject; the call's own subject wins" do
      ghost = Ecto.UUID.generate()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, row} = PhoenixKitAI.create_request(Map.put(base_attrs(), :user_uuid, ghost))
        assert row.subject_key == ghost
        assert row.metadata["unresolved_refs"] == %{"user_uuid" => ghost}

        attrs = Map.merge(base_attrs(), %{user_uuid: ghost, subject_key: "mine"})
        assert {:ok, row} = PhoenixKitAI.create_request(attrs)
        assert row.subject_key == "mine"
      end)
    end

    test "a bad user and a bad endpoint are both kept in unresolved_refs" do
      ghost = Ecto.UUID.generate()

      ExUnit.CaptureLog.capture_log(fn ->
        attrs = Map.merge(base_attrs(), %{user_uuid: "visitor-3", endpoint_uuid: ghost})
        assert {:ok, row} = PhoenixKitAI.create_request(attrs)
        assert row.endpoint_uuid == nil
        assert row.subject_key == "visitor-3"

        assert row.metadata["unresolved_refs"] == %{
                 "user_uuid" => "visitor-3",
                 "endpoint_uuid" => ghost
               }
      end)
    end
  end

  describe "through a verb" do
    test "subject_key: lands on the row and caps that subject alone", %{endpoint: ep} do
      stub_chat()
      {:ok, _} = Budget.set_limit(:user, "0.40")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", subject_key: "visitor-1")
      assert [row] = rows(ep)
      assert row.subject_key == "visitor-1"
      assert row.user_uuid == nil

      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "b", subject_key: "visitor-1")

      # The refusal row says whom it refused.
      assert Enum.any?(rows(ep), &(Request.refused?(&1) and &1.subject_key == "visitor-1"))

      # Another visitor, and a call naming nobody, are not affected.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "c", subject_key: "visitor-2")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "d")
      assert {[_, _], 2} = PhoenixKitAI.list_requests(subject_key: "visitor-1")
    end

    test "the call count caps a subject too, and a cache hit row carries it", %{endpoint: ep} do
      stub_chat(0.0)
      {:ok, _} = Budget.set_limit(:user_calls, 2)

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", subject_key: "v", cache: true)
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "same", subject_key: "v", cache: true)
      assert Enum.all?(rows(ep), &(&1.subject_key == "v"))
      assert Enum.any?(rows(ep), &(&1.metadata["cached"] == true))

      assert [%{scope: :user_calls, spent: 2}] = Budget.status(ep, subject_key: "v")

      assert {:error, {:budget_exceeded, :user_calls}} =
               PhoenixKitAI.ask(ep.uuid, "x", subject_key: "v")
    end

    test "with a user, the user is the per-user scopes' subject", %{endpoint: ep} do
      stub_chat()
      user = Fixtures.confirmed_user_fixture().uuid
      {:ok, _} = Budget.set_limit(:user, "0.40")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", user_uuid: user, subject_key: "tenant-1")
      assert [row] = rows(ep)
      assert row.user_uuid == user
      assert row.subject_key == "tenant-1"

      # The subject's own sum is not what the user's call is checked against.
      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "b", user_uuid: user, subject_key: "tenant-2")

      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "c", subject_key: "tenant-1")
    end

    test "a uuid of no user with a subject_key: the subject is capped, not escaped",
         %{endpoint: ep} do
      stub_chat()
      {:ok, _} = Budget.set_limit(:user, "0.40")
      ghost = Ecto.UUID.generate()

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", user_uuid: ghost, subject_key: "visitor-9")
      assert [%{user_uuid: nil, subject_key: "visitor-9"}] = rows(ep)

      # The rows carry the subject, so the subject is what is counted.
      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "b", user_uuid: ghost, subject_key: "visitor-9")

      assert [%{scope: :user}] = Budget.status(ep, user_uuid: ghost, subject_key: "visitor-9")
    end

    test "the refusal of a uuid of no user is recorded as an event, with no user", %{endpoint: ep} do
      stub_chat()
      {:ok, _} = Budget.set_limit(:user, "0.40")
      ghost = Ecto.UUID.generate()

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", user_uuid: ghost, subject_key: "visitor-5")

      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "b", user_uuid: ghost, subject_key: "visitor-5")

      assert [event] =
               TestRepo.all(
                 from(e in PhoenixKitAI.GuardEvent,
                   where: e.kind == "limit_reached" and e.endpoint_uuid == ^ep.uuid
                 )
               )

      assert event.user_uuid == nil
      assert event.ref == %{"scope" => "budget:user", "subject_key" => "visitor-5"}
    end

    test "with unknown_user_as_subject on, a user_uuid that is no user is capped as its subject",
         %{endpoint: ep} do
      Application.put_env(:phoenix_kit_ai, :unknown_user_as_subject, true)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :unknown_user_as_subject) end)

      stub_chat()
      {:ok, _} = Budget.set_limit(:user, "0.40")
      ghost = Ecto.UUID.generate()

      # A visitor's own id…
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", user_uuid: "visitor-77")

      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "b", user_uuid: "visitor-77")

      # …and a uuid of no user, each its own subject.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "c", user_uuid: ghost)

      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "d", user_uuid: ghost)

      # A real user is still counted as the user.
      user = Fixtures.confirmed_user_fixture().uuid
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "e", user_uuid: user)
    end

    test "a visitor id passed as user_uuid is recorded as the subject; on its own it is not capped",
         %{endpoint: ep} do
      stub_chat()
      {:ok, _} = Budget.set_limit(:user, "0.40")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "a", user_uuid: "visitor-42")
      assert [row] = rows(ep)
      assert row.subject_key == "visitor-42"

      # Unchanged: a non-user `user_uuid:` alone selects no per-user scope…
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "b", user_uuid: "visitor-42")
      # …while naming the same id as the subject counts its rows.
      assert {:error, {:budget_exceeded, :user}} =
               PhoenixKitAI.ask(ep.uuid, "c", subject_key: "visitor-42")
    end
  end
end
