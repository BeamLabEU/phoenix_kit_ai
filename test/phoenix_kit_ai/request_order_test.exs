defmodule PhoenixKitAI.RequestOrderTest do
  @moduledoc """
  `inserted_at` has second precision, so the usage list breaks a tie by uuid:
  paging through rows written in one second neither repeats nor skips one.
  """

  # async: false — see comment in prompt_changeset_test.exs
  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo

  defp row!(model) do
    {:ok, request} =
      PhoenixKitAI.create_request(%{
        endpoint_name: "order",
        model: model,
        request_type: "chat",
        status: "success"
      })

    request
  end

  test "rows of one second page in uuid order, each once" do
    rows = for n <- 1..5, do: row!("m#{n}")
    uuids = Enum.map(rows, & &1.uuid)

    Repo.update_all(from(r in Request, where: r.uuid in ^uuids),
      set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
    )

    for {sort_by, dir} <- [{:inserted_at, :desc}, {:inserted_at, :asc}, {:model, :desc}] do
      paged =
        for page <- 1..5 do
          {[request], 5} =
            PhoenixKitAI.list_requests(
              page: page,
              page_size: 1,
              sort_by: sort_by,
              sort_dir: dir
            )

          request.uuid
        end

      assert Enum.sort(paged) == Enum.sort(uuids), "#{sort_by} #{dir}"
    end

    {listed, 5} = PhoenixKitAI.list_requests(page_size: 10)
    assert Enum.map(listed, & &1.uuid) == Enum.sort(uuids, :desc)
  end
end
