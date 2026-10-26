defmodule PhoenixKitAI.RetentionInvariantTest do
  @moduledoc """
  The content step's bookkeeping under random runs: whatever the periods,
  chunk sizes, caps and time slices, no row below `content_done_before`
  and none inside `content_resume` keeps content, and unlimited runs end
  with everything below the boundary cleared. Deterministic seeds: a
  failure reproduces by its seed. Keep 1..12 here; widen the range
  locally when changing the content step's bookkeeping.

  `async: false`: the last-run stamp and the site time zone are global.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Request, Retention}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @base ~U[2025-01-01 00:00:00Z]

  defp day(d), do: DateTime.add(@base, d * 86_400)

  defp with_content(where) do
    q = from(r in Request, where: fragment("? \\?| ?", r.metadata, ^Retention.content_keys()))

    q =
      case where do
        {:below, at} -> from(r in q, where: r.inserted_at < ^at)
        {:range, nil, up} -> from(r in q, where: r.inserted_at < ^up)
        {:range, lo, up} -> from(r in q, where: r.inserted_at >= ^lo and r.inserted_at < ^up)
      end

    TestRepo.aggregate(q, :count)
  end

  for seed <- 1..12 do
    test "seed #{seed}: nothing below the cleared point or inside the resume keeps content" do
      :rand.seed(:exsss, {unquote(seed), 7, 11})
      PhoenixKit.Settings.update_setting("time_zone", "0")

      # 60 rows over 600 days, two at each time
      for i <- 1..60 do
        at = day(div(i, 2) * 10)

        TestRepo.insert!(%Request{
          model: "m",
          request_type: "chat",
          status: "success",
          metadata: %{"messages" => ["x"], "task" => "t"},
          inserted_at: at,
          updated_at: at
        })
      end

      # all well before the floor: clamping never changes them
      request_cuts = [nil, day(100), day(200), day(300)]
      content_cuts = [day(150), day(250), day(400), day(550)]

      for step <- 1..25 do
        opts = [
          pause_ms: 0,
          request_batch: Enum.random([1, 2, 3]),
          content_batch: Enum.random([1, 2, 3]),
          content_min_batch: 1,
          max_rows: Enum.random([1, 2, 5, 1000]),
          time_limits: %{
            requests: Enum.random([0, 60_000]),
            content: Enum.random([0, 60_000])
          }
        ]

        cutoffs = %{requests: Enum.random(request_cuts), content: Enum.random(content_cuts)}
        assert {:ok, _} = Retention.run(:manual, cutoffs, opts)

        last = Retention.last_run()

        if at = last.content_done_before do
          assert with_content({:below, at}) == 0,
                 "step #{step}: content below content_done_before"
        end

        if resume = last.content_resume do
          assert with_content({:range, resume.lower, resume.upper}) == 0,
                 "step #{step}: content inside content_resume #{inspect(resume)}"
        end
      end

      # unlimited runs finish the largest boundary
      cut = List.last(content_cuts)
      for _ <- 1..3, do: assert({:ok, _} = Retention.run(:manual, %{content: cut}, pause_ms: 0))
      assert with_content({:below, cut}) == 0
    end
  end
end
