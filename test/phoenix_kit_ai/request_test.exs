defmodule PhoenixKitAI.RequestTest do
  # async: false — see comment in prompt_changeset_test.exs
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Request

  describe "format_cost/1" do
    test "returns a dash for nil cost" do
      assert Request.format_cost(nil) == "-"
    end

    test "returns exact $0.00 for zero" do
      assert Request.format_cost(0) == "$0.00"
    end

    test "returns $0.00 for negative nanodollars (cond `true` fallback)" do
      # Pin the `true -> "$0.00"` clause of format_cost/1's cond.
      # The head `format_cost(0)` short-circuits zero exactly; the
      # cond's earlier branches all gate on positive thresholds. A
      # negative integer falls through to the `true` branch.
      assert Request.format_cost(-1) == "$0.00"
      assert Request.format_cost(-1_000_000) == "$0.00"
    end

    test "uses 2 decimals for amounts >= $0.01" do
      # 1_000_000_000 nanodollars = $1.00
      assert Request.format_cost(1_000_000_000) == "$1.00"
      # 10_000_000 nanodollars = $0.01
      assert Request.format_cost(10_000_000) == "$0.01"
    end

    test "uses 4 decimals for amounts between $0.0001 and $0.01" do
      # 1_000_000 nanodollars = $0.001
      result = Request.format_cost(1_000_000)
      assert result =~ "$0.00"
      assert String.length(result) >= 6
    end

    test "uses 6 decimals for amounts between $0.000001 and $0.0001" do
      # 30_000 nanodollars = $0.00003
      assert Request.format_cost(30_000) == "$0.000030"
    end

    test "uses 9 decimals below a millionth of a dollar" do
      # 40 nanodollars = $0.00000004, a 2-token embedding
      assert Request.format_cost(40) == "$0.000000040"
      assert Request.format_cost(1) == "$0.000000001"
    end
  end

  describe "changeset/2 validation" do
    test "allows a minimal valid request" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Req test endpoint #{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      attrs = %{
        endpoint_uuid: endpoint.uuid,
        endpoint_name: endpoint.name,
        model: endpoint.model,
        status: "success",
        input_tokens: 5,
        output_tokens: 10,
        total_tokens: 15
      }

      changeset = Request.changeset(%Request{}, attrs)
      assert changeset.valid?
    end

    test "rejects unknown status values" do
      changeset =
        Request.changeset(%Request{}, %{
          model: "a/b",
          status: "weird"
        })

      refute changeset.valid?
    end
  end

  describe "create_request/1 (integration)" do
    test "persists a request row" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Persist endpoint #{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "a/b",
          api_key: "sk-test-key"
        })

      {:ok, request} =
        PhoenixKitAI.create_request(%{
          endpoint_uuid: endpoint.uuid,
          endpoint_name: endpoint.name,
          model: endpoint.model,
          status: "success",
          input_tokens: 1,
          output_tokens: 2,
          total_tokens: 3,
          latency_ms: 50
        })

      assert request.uuid
      assert request.status == "success"
      assert request.total_tokens == 3
    end
  end
end
