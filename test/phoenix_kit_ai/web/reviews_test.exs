defmodule PhoenixKitAI.Web.ReviewsTest do
  @moduledoc """
  AI → Reviews: the list for every `ai` holder, deciding only with
  `ai.manage` (checked per event), a handler's refusal shown, not hidden.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Review, Reviews}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    # `ai.manage` counts only while the module is registered (core's
    # `Permissions.feature_enabled?/1`), as on the Tasks page's tests.
    :ok = PhoenixKit.ModuleRegistry.register(PhoenixKitAI)
    on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(PhoenixKitAI) end)

    # The first user is the Owner.
    owner = Fixtures.user_fixture()
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :review_handlers) end)
    {:ok, owner: owner}
  end

  defp admin(keys) do
    user = Fixtures.user_fixture()
    {:ok, _} = Roles.assign_role(user, "Admin")
    %{uuid: role_uuid} = Roles.get_role_by_name("Admin")
    :ok = Permissions.set_permissions(role_uuid, keys)
    {user, role_uuid}
  end

  defp open(conn, user, query \\ "") do
    {:ok, view, _html} =
      conn |> put_test_scope(Scope.for_user(user)) |> live("/en/admin/ai/reviews" <> query)

    view
  end

  defp review(attrs \\ %{}) do
    {:ok, review} =
      Reviews.create(
        Map.merge(%{kind: "listing_text", subject_id: "7", payload: %{"t" => "Hi"}}, attrs)
      )

    review
  end

  test "an Owner sees pending reviews and confirms one with a note", %{conn: conn, owner: owner} do
    r = review()
    view = open(conn, owner)

    assert has_element?(view, "#ai-review-#{r.uuid}[data-status=pending]")
    assert has_element?(view, "#ai-review-#{r.uuid} [data-summary]", ~s("t":"Hi"))

    view
    |> form("#ai-review-form-#{r.uuid}", %{"note" => "fine"})
    |> render_submit(%{"decision" => "confirmed"})

    assert render(view) =~ "Review confirmed"

    assert %Review{status: "confirmed", decision_note: "fine", decided_by_uuid: by} =
             TestRepo.get!(Review, r.uuid)

    assert by == owner.uuid
    # Gone from the pending list, there under "confirmed".
    refute has_element?(view, "#ai-review-#{r.uuid}")
    view = open(conn, owner, "?status=confirmed")
    assert has_element?(view, "#ai-review-#{r.uuid}[data-status=confirmed]")
  end

  test "without ai.manage the list is read-only and a decision is refused", %{conn: conn} do
    r = review()
    {user, _role} = admin(["ai"])
    view = open(conn, user)

    assert has_element?(view, "#ai-reviews-read-only")
    assert has_element?(view, "#ai-review-#{r.uuid}")
    refute has_element?(view, "#ai-review-form-#{r.uuid}")

    assert render_hook(view, "decide", %{"uuid" => r.uuid, "decision" => "confirmed"}) =~
             "You may not decide AI reviews"

    assert TestRepo.get!(Review, r.uuid).status == "pending"
  end

  test "a permission taken away while the page is open is refused at the next event", %{
    conn: conn
  } do
    r = review()
    {user, role_uuid} = admin(["ai", "ai.manage"])
    view = open(conn, user)
    assert has_element?(view, "#ai-review-form-#{r.uuid}")

    :ok = Permissions.set_permissions(role_uuid, ["ai"])

    assert render_hook(view, "decide", %{"uuid" => r.uuid, "decision" => "rejected"}) =~
             "You may not decide AI reviews"

    assert TestRepo.get!(Review, r.uuid).status == "pending"
  end

  defmodule RefusingHandler do
    @moduledoc false
    def on_decide(_review), do: {:error, :not_now}
    def summary(review), do: "Listing #{review.subject_id}"
  end

  test "a handler that refuses leaves the review pending, and its summary is shown",
       %{conn: conn, owner: owner} do
    Application.put_env(:phoenix_kit_ai, :review_handlers, %{"listing_text" => RefusingHandler})
    r = review()
    view = open(conn, owner)
    assert has_element?(view, "#ai-review-#{r.uuid} [data-summary]", "Listing 7")

    assert render_hook(view, "decide", %{"uuid" => r.uuid, "decision" => "confirmed"}) =~
             "could not apply this decision"

    assert TestRepo.get!(Review, r.uuid).status == "pending"
  end

  test "a review decided elsewhere is answered as already decided", %{conn: conn, owner: owner} do
    r = review()
    view = open(conn, owner)
    {:ok, _} = Reviews.reject(r)

    assert render_hook(view, "decide", %{"uuid" => r.uuid, "decision" => "confirmed"}) =~
             "already been decided"
  end

  test "filters by kind", %{conn: conn, owner: owner} do
    a = review()
    b = review(%{kind: "other_kind"})
    view = open(conn, owner, "?kind=other_kind")
    assert has_element?(view, "#ai-review-#{b.uuid}")
    refute has_element?(view, "#ai-review-#{a.uuid}")
  end
end
