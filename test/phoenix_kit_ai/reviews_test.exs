defmodule PhoenixKitAI.ReviewsTest do
  @moduledoc """
  The review envelope (`PhoenixKitAI.Reviews`): pending → confirmed or
  rejected, decided once, the app's `on_decide` in the decision's transaction.
  """

  use PhoenixKitAI.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Request, Review, Reviews}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  defmodule Handler do
    @moduledoc false
    @behaviour PhoenixKitAI.ReviewHandler

    @impl true
    def on_decide(%PhoenixKitAI.Review{payload: %{"fail" => true}}), do: {:error, :nope}
    def on_decide(%PhoenixKitAI.Review{payload: %{"raise" => true}}), do: raise("boom")

    def on_decide(review) do
      send(self(), {:decided, review.uuid, review.status, review.payload})
      :ok
    end

    @impl true
    def summary(review), do: "Summary of #{review.subject_id}"
  end

  setup do
    Application.put_env(:phoenix_kit_ai, :review_handlers, %{"test.kind" => Handler})
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :review_handlers) end)
    :ok
  end

  defp review(attrs \\ %{}) do
    {:ok, review} =
      Reviews.create(
        Map.merge(
          %{
            kind: "test.kind",
            subject_type: "listing",
            subject_id: 42,
            payload: %{"text" => "Hi"}
          },
          attrs
        )
      )

    review
  end

  defp admin_with(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    {user, role_uuid}
  end

  test "create/1 makes a pending review; the subject id is a string" do
    review = review()
    assert %Review{status: "pending", kind: "test.kind", subject_id: "42"} = review
    assert Review.pending?(review)
    assert {:error, %Ecto.Changeset{}} = Reviews.create(%{payload: %{}})
    assert {:error, %Ecto.Changeset{}} = Reviews.create(%{kind: String.duplicate("k", 101)})
  end

  test "a review is decided once; the handler runs with the decided review" do
    review = review()
    assert {:ok, %Review{status: "confirmed", decided_at: %DateTime{}}} = Reviews.confirm(review)
    uuid = review.uuid
    assert_received {:decided, ^uuid, "confirmed", %{"text" => "Hi"}}

    assert {:error, {:already_decided, "confirmed"}} = Reviews.reject(review.uuid)
    assert {:error, {:already_decided, "confirmed"}} = Reviews.confirm(review.uuid)
    refute_received {:decided, _, _, _}

    assert {:error, :not_found} = Reviews.confirm(Ecto.UUID.generate())
    assert {:error, :not_found} = Reviews.confirm("nope")
    assert {:error, :invalid_decision} = Reviews.decide(review(), :maybe)
  end

  test "of two decisions racing, exactly one wins" do
    review = review()
    parent = self()

    results =
      for decision <- [:confirmed, :rejected, :confirmed, :rejected] do
        Task.async(fn ->
          Sandbox.allow(TestRepo, parent, self())
          Reviews.decide(review.uuid, decision, on_decide: fn _ -> :ok end)
        end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:already_decided, _}}, &1)) == 3
  end

  test "a handler's error or raise rolls the decision back; the review stays pending" do
    failing = review(%{payload: %{"fail" => true}})
    assert {:error, {:on_decide_failed, :nope}} = Reviews.confirm(failing)
    assert TestRepo.get!(Review, failing.uuid).status == "pending"

    raising = review(%{payload: %{"raise" => true}})
    assert {:error, {:on_decide_failed, {:raised, RuntimeError}}} = Reviews.reject(raising)
    assert TestRepo.get!(Review, raising.uuid).status == "pending"

    # Decided again later, with a handler that agrees, it goes through.
    assert {:ok, %Review{status: "rejected"}} =
             Reviews.reject(raising, on_decide: fn _review -> {:ok, :done} end)
  end

  test "a handler that throws or exits rolls back too, and decide/3 still returns" do
    thrown = review()

    assert {:error, {:on_decide_failed, {:thrown, :term}}} =
             Reviews.confirm(thrown, on_decide: fn _ -> throw(:secret) end)

    assert TestRepo.get!(Review, thrown.uuid).status == "pending"

    exited = review()

    assert {:error, {:on_decide_failed, {:exited, :term}}} =
             Reviews.confirm(exited, on_decide: fn _ -> exit(:secret) end)

    assert TestRepo.get!(Review, exited.uuid).status == "pending"
  end

  test "an actor_uuid that names no user is refused, not raised; a real one is recorded" do
    review = review()
    assert {:error, :unknown_actor} = Reviews.confirm(review, actor_uuid: Ecto.UUID.generate())
    assert TestRepo.get!(Review, review.uuid).status == "pending"

    user = Fixtures.user_fixture()
    assert {:ok, %Review{decided_by_uuid: by}} = Reviews.confirm(review, actor_uuid: user.uuid)
    assert by == user.uuid
  end

  test "lengths are counted in code points, as the columns count them" do
    # 100 graphemes of two code points each: 200 characters to Postgres.
    combining = String.duplicate("e\u0301", 100)
    assert {:error, %Ecto.Changeset{}} = Reviews.create(%{kind: combining})

    assert {:error, %Ecto.Changeset{}} =
             Reviews.create(%{kind: "k", subject_id: combining <> String.duplicate("x", 100)})

    review = review()

    assert {:ok, %Review{decision_note: note}} =
             Reviews.reject(review, note: String.duplicate("e\u0301", 1_000))

    assert String.length(note) == 500
    assert length(String.codepoints(note)) == 1_000
  end

  test "on_decide: wins over the configured handler; a kind with no handler has no effect" do
    review = review()

    assert {:ok, _} =
             Reviews.reject(review, on_decide: fn r -> send(self(), {:own, r.status}) && :ok end)

    assert_received {:own, "rejected"}
    refute_received {:decided, _, _, _}

    other = review(%{kind: "unhandled.kind"})
    assert {:ok, %Review{status: "confirmed"}} = Reviews.confirm(other)

    bad = review()

    assert {:error, {:on_decide_failed, {:unexpected_return, :term}}} =
             Reviews.confirm(bad, on_decide: fn _ -> "whatever" end)
  end

  test "a confirmation may carry the reviewer's edit; the proposal is kept" do
    review = review()

    assert {:ok, %Review{payload: %{"text" => "Hello"}, metadata: metadata}} =
             Reviews.confirm(review, payload: %{"text" => "Hello"}, note: "  fixed the greeting ")

    assert metadata["proposed_payload"] == %{"text" => "Hi"}
    assert TestRepo.get!(Review, review.uuid).decision_note == "fixed the greeting"
    uuid = review.uuid
    assert_received {:decided, ^uuid, "confirmed", %{"text" => "Hello"}}

    # What was proposed is the payload at the decision, not a value the
    # creator put in metadata under that name.
    planted = review(%{metadata: %{"proposed_payload" => %{"text" => "planted"}}})

    assert {:ok, %Review{metadata: %{"proposed_payload" => %{"text" => "Hi"}}}} =
             Reviews.confirm(planted, payload: %{"text" => "Edited"})
  end

  test "with a scope, deciding needs ai.manage or an Owner, and records the person" do
    owner = Fixtures.user_fixture()
    {admin, _role_uuid} = admin_with(["ai"])

    assert {:error, :forbidden} = Reviews.confirm(review(), scope: Scope.for_user(admin))
    assert {:error, :forbidden} = Reviews.confirm(review(), scope: :not_a_scope)

    assert {:ok, %Review{decided_by_uuid: by}} =
             Reviews.reject(review(), scope: Scope.for_user(owner))

    assert by == owner.uuid
    assert_activity_logged("review.rejected", actor_uuid: owner.uuid)
  end

  test "list/1 and count/1 filter by status, kind and subject" do
    a = review(%{subject_id: "a"})
    _b = review(%{subject_id: "b", kind: "other.kind"})
    {:ok, _} = Reviews.confirm(a)

    assert [%Review{subject_id: "b"}] = Reviews.list(status: :pending)
    assert [%Review{subject_id: "a"}] = Reviews.list(status: "confirmed", kind: "test.kind")
    assert length(Reviews.list(status: ["pending", "confirmed"])) == 2
    assert Reviews.count(subject_type: "listing", subject_id: "a") == 1
    assert Reviews.count() == 2
  end

  test "the journal row a review names may be deleted: the review keeps going" do
    {:ok, row} =
      PhoenixKitAI.create_request(%{status: "success", model: "m", request_type: "chat"})

    review = review(%{request_uuid: row.uuid})
    TestRepo.delete_all(from(r in Request, where: r.uuid == ^row.uuid))
    assert %Review{request_uuid: nil} = Reviews.get(review.uuid)
    assert :ok = PhoenixKitAI.Retention.check_foreign_keys()
  end

  test "creating and deciding are broadcast by uuid" do
    :ok = Reviews.subscribe()
    review = review()
    uuid = review.uuid
    assert_receive {:review_created, ^uuid}
    {:ok, _} = Reviews.confirm(review)
    assert_receive {:review_decided, ^uuid}
  end
end
