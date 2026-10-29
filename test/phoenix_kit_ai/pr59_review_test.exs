defmodule PhoenixKitAI.PR59ReviewTest do
  use PhoenixKitAI.DataCase, async: false

  @moduletag :capture_log

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>
  @png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9>>

  setup do
    PhoenixKitAI.RequestCache.clear()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "PR59 #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "review/vision",
        api_key: "sk-or-v1-test-key"
      })

    %{endpoint: endpoint}
  end

  defp answer(conn, content, cost) do
    Req.Test.json(conn, %{
      "model" => "review/vision",
      "choices" => [%{"message" => %{"content" => content}, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => cost}
    })
  end

  defp contradiction do
    Jason.encode!(%{
      "results" => [
        %{
          "n" => 1,
          "verdict" => "contradicted",
          "image" => 1,
          "evidence" => "A dog is visible",
          "box_2d" => [100, 100, 500, 500]
        }
      ]
    })
  end

  test "embedding cache hits return zero cost with and without a usage row", %{endpoint: ep} do
    calls = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(calls, 1, 1)

      Req.Test.json(conn, %{
        "data" => [%{"embedding" => [0.1, 0.2], "index" => 0}],
        "usage" => %{"prompt_tokens" => 10, "cost" => 0.003}
      })
    end)

    assert {:ok, %{"cost" => original}} = PhoenixKitAI.embed(ep.uuid, "sofa", cache: true)
    assert Decimal.equal?(original, Decimal.new("0.003"))

    for logged? <- [true, false] do
      assert {:ok, %{"cost" => cost, "request_uuid" => uuid}} =
               PhoenixKitAI.embed(ep.uuid, "sofa", cache: true, log_cache_hit: logged?)

      assert Decimal.equal?(cost, Decimal.new(0))

      if logged? do
        assert %Request{cost: row_cost, metadata: %{"cached" => true}} = Repo.get!(Request, uuid)
        assert Decimal.equal?(cost, row_cost)
      else
        assert is_nil(uuid)
      end
    end

    assert :counters.get(calls, 1) == 1
  end

  test "embedding image limits cover all images in the request", %{endpoint: ep} do
    calls = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(calls, 1, 1)
      Req.Test.json(conn, %{"data" => []})
    end)

    total = byte_size(@jpeg) + byte_size(@png)
    limit = total - 1

    assert {:error, {:image_too_large, ^total, ^limit}} =
             PhoenixKitAI.embed(ep.uuid, ["caption", {:image, @jpeg}, %{image: @png}],
               max_total_input_bytes: limit
             )

    assert :counters.get(calls, 1) == 0
    assert Repo.all(from(r in Request, where: r.endpoint_uuid == ^ep.uuid)) == []
  end

  test "a failed confirmation is counted once in a batch budget", %{endpoint: ep} do
    calls = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(calls, 1, 1)

      case :counters.get(calls, 1) do
        1 -> answer(conn, contradiction(), 0.002)
        2 -> answer(conn, "not JSON", 0.003)
        3 -> answer(conn, ~s({"results": []}), 0.001)
      end
    end)

    assert {:ok, %{items: [first, second], cost: cost, run: run}} =
             PhoenixKitAI.vision_batch(
               ep.uuid,
               [
                 %{images: @jpeg, statements: ["A cat"]},
                 %{images: @png, statements: ["A cat"]}
               ],
               verb: :check_statements,
               confirm: true,
               concurrency: 1,
               budget: "0.006",
               cache: false
             )

    assert first.status == :ok
    assert Decimal.equal?(first.cost, Decimal.new("0.005"))
    assert second.status == :ok
    assert Decimal.equal?(cost, Decimal.new("0.006"))
    assert {:ok, %{total: %{cost: journal_cost}}} = PhoenixKitAI.run_costs(run)
    assert Decimal.equal?(cost, journal_cost)
  end

  test "failed confirmation accounting preserves earlier fallback costs", %{endpoint: ep} do
    calls = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(calls, 1, 1)

      case :counters.get(calls, 1) do
        1 -> answer(conn, "not JSON", 0.001)
        2 -> answer(conn, contradiction(), 0.002)
        3 -> answer(conn, "not JSON", 0.003)
        4 -> answer(conn, "not JSON", 0.004)
      end
    end)

    assert {:ok, %{items: [item], cost: cost, run: run}} =
             PhoenixKitAI.vision_batch(
               ep.uuid,
               [%{images: @jpeg, statements: ["A cat"]}],
               verb: :check_statements,
               confirm: true,
               fallback_models: ["review/backup"],
               cache: false
             )

    assert item.status == :ok
    assert Decimal.equal?(cost, Decimal.new("0.010"))
    assert {:ok, %{total: %{cost: journal_cost}}} = PhoenixKitAI.run_costs(run)
    assert Decimal.equal?(cost, journal_cost)
  end

  test "a default user's refusal does not skip an item overriding the user", %{endpoint: ep} do
    capped = Fixtures.user_fixture()
    other = Fixtures.user_fixture()
    Req.Test.stub(__MODULE__, &answer(&1, "A chair", 0.003))

    {:ok, _} = PhoenixKitAI.Budget.set_limit(:user, "0.002")
    on_exit(fn -> PhoenixKitAI.Budget.set_limit(:user, 0) end)

    assert {:ok, _} =
             PhoenixKitAI.describe_image(ep.uuid, @jpeg, user_uuid: capped.uuid, cache: false)

    assert {:ok, %{items: [first, second], stopped: nil}} =
             PhoenixKitAI.vision_batch(
               ep.uuid,
               [%{images: @jpeg}, %{images: @png, opts: [user_uuid: other.uuid]}],
               user_uuid: capped.uuid,
               concurrency: 1,
               cache: false
             )

    assert %{status: :error, error: {:budget_exceeded, :user}} = first
    assert %{status: :ok} = second
  end

  test "a batch crash log excludes arguments from exception stack frames", %{endpoint: ep} do
    secret = "private-image-caption-sk-test-key"

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, _conn} = Plug.Conn.read_body(conn)
      %{"messages" => [%{"content" => [%{"text" => text} | _]}]} = Jason.decode!(raw)
      :erlang.binary_to_integer(text)
    end)

    log =
      capture_log(fn ->
        assert {:ok, %{items: [%{status: :error, error: {:exception, ArgumentError}}]}} =
                 PhoenixKitAI.vision_batch(ep.uuid, [@jpeg], prompt: secret, cache: false)
      end)

    assert log =~ "[PhoenixKitAI.VisionBatch] item crashed: ArgumentError"
    assert log =~ ":erlang.binary_to_integer/1"
    refute log =~ secret
  end
end
