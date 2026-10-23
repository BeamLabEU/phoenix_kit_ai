defmodule PhoenixKitAI.EndpointNameAndSourcePrefixTest do
  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.Test.Repo

  defp endpoint!(attrs) do
    base = %{provider: "openrouter", model: "a/b", api_key: "sk-test-key"}
    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp set_inserted_at(uuid, at) do
    PhoenixKitAI.Endpoint
    |> where([e], e.uuid == ^uuid)
    |> Repo.update_all(set: [inserted_at: at])
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
      second = endpoint!(%{name: "Twin "})

      # Two rows made in one test share a second (and maybe a millisecond, where
      # UUIDv7 order is random), so the ages are set apart explicitly.
      set_inserted_at(first.uuid, ~U[2026-01-01 00:00:00Z])
      set_inserted_at(second.uuid, ~U[2026-01-01 00:00:01Z])

      for _ <- 1..5, do: assert(PhoenixKitAI.get_endpoint_by_name("twin").uuid == first.uuid)
    end

    test "endpoints created in the same second: the lower uuid wins, whatever the row order" do
      a = endpoint!(%{name: " Tie"})
      b = endpoint!(%{name: "Tie "})

      # UUIDv7 is random within one millisecond, so which row has the lower uuid
      # is not known in advance.
      [lower, higher] = Enum.sort([a.uuid, b.uuid])

      # Touching the lower-uuid row last leaves it physically after the other one,
      # so only the uuid tiebreaker can put it first.
      for uuid <- [higher, lower], do: set_inserted_at(uuid, ~U[2026-01-01 00:00:00Z])

      for _ <- 1..5, do: assert(PhoenixKitAI.get_endpoint_by_name("tie").uuid == lower)
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
        PhoenixKitAI.list_requests(endpoint_uuid: ep.uuid, source_prefix: "App.")

      assert requests |> Enum.map(& &1.metadata["source"]) |> Enum.sort() == [
               "App.Foo",
               "App.FooBar"
             ]

      assert PhoenixKitAI.get_usage_stats(endpoint_uuid: ep.uuid, source_prefix: "App.").total_requests ==
               2
    end

    test "LIKE wildcards in the prefix are literal", %{ep: ep} do
      {requests, _} = PhoenixKitAI.list_requests(endpoint_uuid: ep.uuid, source_prefix: "A_")
      assert Enum.map(requests, & &1.metadata["source"]) == ["A_b"]
    end
  end
end
