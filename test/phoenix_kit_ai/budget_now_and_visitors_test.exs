defmodule PhoenixKitAI.BudgetNowAndVisitorsTest do
  @moduledoc """
  Two edges of the spend caps: the windows are taken at the `now` a check is
  given (the refusal's event uses the same one, so a check just before the
  month turns and its event just after agree), and a `user_uuid:` that is not
  a uuid — a visitor's own id — has no user scope instead of a failed read.
  """

  use PhoenixKitAI.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.{Budget, Request, RequestCache}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "0")
    reset()
    on_exit(&reset/0)

    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Now-EP-#{System.unique_integer([:positive])}",
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

  defp spend(endpoint, at, cost) do
    %Request{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      status: "success",
      cost: Decimal.new(cost),
      latency_ms: 1,
      metadata: %{},
      inserted_at: at,
      updated_at: at
    }
    |> TestRepo.insert!()
  end

  test "the monthly cap counts the month of the `now` it is given", %{endpoint: ep} do
    {:ok, _} = Budget.set_limit(:global_month, "1.00")
    last_month = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1)
    {:ok, late} = DateTime.new(last_month, ~T[23:59:59])
    spend(ep, DateTime.add(late, -3_600), "1.00")

    assert {:error, {:budget_exceeded, :global_month}} = Budget.check(ep, [], late)
    assert :ok = Budget.check(ep, [], DateTime.utc_now())
  end

  test "a user_uuid that is not a uuid has no user scope, and no read is reported as failed",
       %{endpoint: ep} do
    {:ok, _} = Budget.set_limit(:user, "1.00")
    {:ok, _} = Budget.set_limit(:user_calls, 5)

    log =
      capture_log(fn ->
        for id <- ["visitor-42", "", "0123456789abcdef"] do
          assert :ok = Budget.check(ep, user_uuid: id)
          assert Budget.status(ep, user_uuid: id) == []
        end
      end)

    refute log =~ "could not read"

    user_uuid = Fixtures.user_fixture().uuid
    assert [%{scope: :user}, %{scope: :user_calls}] = Budget.status(ep, user_uuid: user_uuid)
  end
end
