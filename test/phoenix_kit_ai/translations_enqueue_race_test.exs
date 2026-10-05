defmodule PhoenixKitAI.TranslationsEnqueueRaceTest do
  @moduledoc """
  `Translations.enqueue/1` under real concurrency.

  A double click — or the same page open in two tabs — used to queue the
  same translation twice: "is a job in flight?" and the insert were two
  steps, and both callers ran the first before either ran the second.

  The Ecto sandbox cannot show this. In shared mode every process talks
  through ONE connection, so the callers are serialized by the test itself
  and the race never happens. This test therefore runs outside the sandbox,
  on real connections that really commit, and deletes its own rows after.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAI.Test.Repo, as: TestRepo
  alias PhoenixKitAI.Translations

  @moduletag :integration

  @callers 16

  setup do
    resource_uuid = Ecto.UUID.generate()

    # Registered BEFORE anything can fail, so a setup that dies half-way
    # still hands the next test its sandbox back.
    on_exit(fn ->
      Sandbox.mode(TestRepo, :auto)

      TestRepo.delete_all(
        from(j in "oban_jobs", where: fragment("?->>'resource_uuid' = ?", j.args, ^resource_uuid))
      )

      Sandbox.mode(TestRepo, :manual)
    end)

    Sandbox.mode(TestRepo, :auto)
    start_supervised!({Oban, name: Oban, repo: TestRepo, testing: :manual})

    %{
      params: %{
        resource_type: "race_probe",
        resource_uuid: resource_uuid,
        endpoint_uuid: Ecto.UUID.generate(),
        prompt_uuid: Ecto.UUID.generate(),
        source_lang: "en",
        target_lang: "de"
      }
    }
  end

  defp jobs_for(resource_uuid, target_lang) do
    TestRepo.aggregate(
      from(j in "oban_jobs",
        where: fragment("?->>'resource_uuid' = ?", j.args, ^resource_uuid),
        where: fragment("?->>'target_lang' = ?", j.args, ^target_lang)
      ),
      :count
    )
  end

  # Everyone waits at the gate and is let go at once — as close to one
  # instant as a test can get.
  defp race(fun) do
    gate = make_ref()
    parent = self()

    tasks =
      for _ <- 1..@callers do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            ^gate -> fun.()
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    for task <- tasks, do: send(task.pid, gate)

    Task.await_many(tasks, 30_000)
  end

  test "#{@callers} callers at once queue the translation exactly once", %{params: params} do
    results = race(fn -> Translations.enqueue(params) end)

    assert Enum.all?(results, &match?({:ok, %{conflict?: _}}, &1))
    assert Enum.count(results, &(&1 == {:ok, %{conflict?: false}})) == 1
    assert Enum.count(results, &(&1 == {:ok, %{conflict?: true}})) == @callers - 1
    assert jobs_for(params.resource_uuid, "de") == 1
  end

  # A host may queue many jobs inside ONE transaction of its own. There the
  # enqueue must not open a nested transaction or take a lock held until the
  # tick commits — and a refused insert must not poison the caller's.
  test "inside a caller's transaction it queues without nesting one", %{params: params} do
    assert {:ok, results} =
             TestRepo.transaction(fn ->
               first = Translations.enqueue(params)
               second = Translations.enqueue(params)
               other = Translations.enqueue(%{params | target_lang: "fr"})
               # the caller's transaction is still usable afterwards
               assert %{rows: [[1]]} = TestRepo.query!("SELECT 1")
               [first, second, other]
             end)

    assert results == [
             {:ok, %{conflict?: false}},
             {:ok, %{conflict?: true}},
             {:ok, %{conflict?: false}}
           ]

    assert jobs_for(params.resource_uuid, "de") == 1
    assert jobs_for(params.resource_uuid, "fr") == 1
  end

  test "a different target language is not made to wait for, or conflict with, this one", %{
    params: params
  } do
    langs = for i <- 1..@callers, do: "l#{i}"
    {:ok, agent} = Agent.start_link(fn -> langs end)

    results =
      race(fn ->
        lang = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
        Translations.enqueue(%{params | target_lang: lang})
      end)

    assert Enum.all?(results, &(&1 == {:ok, %{conflict?: false}}))
    for lang <- langs, do: assert(jobs_for(params.resource_uuid, lang) == 1)
  end
end
