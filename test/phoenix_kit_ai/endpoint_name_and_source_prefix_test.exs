defmodule PhoenixKitAI.EndpointNameAndSourcePrefixTest do
  use PhoenixKitAI.DataCase, async: false

  defp endpoint!(attrs) do
    base = %{provider: "openrouter", model: "a/b", api_key: "sk-test-key"}
    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  describe "get_endpoint_by_name/1" do
    test "matches case-insensitively and ignores surrounding spaces" do
      ep = endpoint!(%{name: "Label Reader"})

      for name <- ["Label Reader", "label reader", "  LABEL READER  "] do
        assert %{uuid: uuid} = PhoenixKitAI.get_endpoint_by_name(name)
        assert uuid == ep.uuid
      end

      assert {:ok, %{uuid: _}} = PhoenixKitAI.resolve_endpoint_by_name("label reader")
    end

    test "a name stored with surrounding spaces is found, and the exact name wins" do
      padded = endpoint!(%{name: " Padded reader "})
      assert PhoenixKitAI.get_endpoint_by_name("padded reader").uuid == padded.uuid

      exact = endpoint!(%{name: "padded reader"})
      assert PhoenixKitAI.get_endpoint_by_name("Padded Reader").uuid == exact.uuid
    end

    test "with no exact name, the oldest endpoint wins every time" do
      first = endpoint!(%{name: " Twin"})
      _second = endpoint!(%{name: "Twin "})

      for _ <- 1..5, do: assert(PhoenixKitAI.get_endpoint_by_name("twin").uuid == first.uuid)
    end

    test "unknown, blank or non-string names are nil" do
      assert PhoenixKitAI.get_endpoint_by_name("nothing like it") == nil
      assert PhoenixKitAI.get_endpoint_by_name("  ") == nil
      assert PhoenixKitAI.get_endpoint_by_name(nil) == nil
      assert {:error, :endpoint_not_found} = PhoenixKitAI.resolve_endpoint_by_name("nope")
    end

    test "a disabled endpoint is still found (calling it is refused elsewhere)" do
      ep = endpoint!(%{name: "Old reader", enabled: false})
      assert PhoenixKitAI.get_endpoint_by_name("old reader").uuid == ep.uuid
    end
  end

  describe "Request.badge_status/1" do
    test "maps request statuses onto core's badge colours" do
      assert PhoenixKitAI.Request.badge_status("success") == "completed"
      assert PhoenixKitAI.Request.badge_status("error") == "error"
      assert PhoenixKitAI.Request.badge_status("timeout") == "offline"
      assert PhoenixKitAI.Request.badge_status("anything") == "unknown"
    end
  end

  describe "source_prefix:" do
    setup do
      ep = endpoint!(%{name: "Stats #{System.unique_integer([:positive])}"})

      for source <- ["App.Foo", "App.FooBar", "Other.Thing", "A_b", "AXb"] do
        {:ok, _} =
          PhoenixKitAI.create_request(%{
            endpoint_uuid: ep.uuid,
            endpoint_name: ep.name,
            model: "a/b",
            status: "success",
            metadata: %{"source" => source}
          })
      end

      %{ep: ep}
    end

    test "counts every source starting with the prefix", %{ep: ep} do
      {requests, _total} =
        list(endpoint_uuid: ep.uuid, source_prefix: "App.")

      assert requests |> Enum.map(& &1.metadata["source"]) |> Enum.sort() == [
               "App.Foo",
               "App.FooBar"
             ]

      assert PhoenixKitAI.get_usage_stats(endpoint_uuid: ep.uuid, source_prefix: "App.").total_requests ==
               2
    end

    test "LIKE wildcards in the prefix are literal", %{ep: ep} do
      {requests, _} = list(endpoint_uuid: ep.uuid, source_prefix: "A_")
      assert Enum.map(requests, & &1.metadata["source"]) == ["A_b"]
    end
  end

  defp list(opts) do
    case PhoenixKitAI.list_requests(opts) do
      {requests, total} -> {requests, total}
      %{requests: requests} = page -> {requests, page[:total]}
      requests when is_list(requests) -> {requests, length(requests)}
    end
  end
end
