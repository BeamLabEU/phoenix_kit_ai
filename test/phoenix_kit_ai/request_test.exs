defmodule PhoenixKitAI.RequestTest do
  # async: false — see comment in prompt_changeset_test.exs
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Request

  describe "format_cost/1" do
    defp cost(dollars), do: Request.format_cost(Decimal.new(dollars))

    test "returns a dash for nil cost" do
      assert Request.format_cost(nil) == "-"
    end

    test "returns $0.00 for zero" do
      assert cost("0") == "$0.00"
      assert cost("0.0000000000") == "$0.00"
    end

    test "uses 2 decimals for amounts >= $0.01" do
      assert cost("1") == "$1.00"
      assert cost("1.5") == "$1.50"
      assert cost("0.01") == "$0.01"
    end

    test "uses 4 decimals for amounts between $0.0001 and $0.01" do
      assert cost("0.001") == "$0.0010"
      assert cost("0.0017") == "$0.0017"
    end

    test "uses 6 decimals for amounts between $0.000001 and $0.0001" do
      assert cost("0.00003") == "$0.000030"
    end

    test "uses 10 decimals below a millionth of a dollar" do
      # a 2-token embedding at $0.00000004
      assert cost("0.00000004") == "$0.0000000400"
      assert cost("0.0000000001") == "$0.0000000001"
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

    test "a cost is dollars, not negative, at most 10 decimal places" do
      valid? = fn cost ->
        Request.changeset(%Request{}, %{status: "success", cost: cost}).valid?
      end

      assert valid?.(Decimal.new("0.0000000001"))
      assert valid?.(Decimal.new("0.00003"))
      assert valid?.("1.50")
      assert valid?.(nil)
      refute valid?.(Decimal.new("-0.01"))
      # past the column's scale: refused, not silently rounded
      refute valid?.(Decimal.new("0.00000000001"))
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
