defmodule PhoenixKitAI.ManualPriceRightsTest do
  @moduledoc """
  A manual price steers the money limits, so setting, changing or removing
  one needs `ai.manage` (an Owner always), passed as the `:scope` option —
  as a capability declaration does while only verified models are allowed.
  A price dropped because the endpoint's model changed needs nothing: it no
  longer applies.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}

  @pricing %{"input" => 600_000, "output" => 2_200_000}

  setup do
    PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(PhoenixKitAI)
    on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)

    # The first user registered is the Owner.
    owner = Fixtures.user_fixture()
    {:ok, owner: Scope.for_user(owner)}
  end

  defp scope_with(keys) do
    user = Fixtures.user_fixture()
    {:ok, role} = Roles.create_role(%{name: "Role #{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.assign_role(user, role.name)
    :ok = Permissions.set_permissions(role.uuid, keys)
    Scope.for_user(user)
  end

  defp attrs(provider_settings) do
    %{
      name: "Rights #{System.unique_integer([:positive])}",
      provider: "zai",
      model: "glm-4.6",
      api_key: "zai-test-key",
      provider_settings: provider_settings
    }
  end

  defp priced(owner) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(attrs(%{"pricing" => @pricing}), scope: owner)

    endpoint
  end

  test "setting a price needs ai.manage", %{owner: owner} do
    for scope <- [nil, scope_with(["ai"])] do
      assert {:error, changeset} =
               PhoenixKitAI.create_endpoint(attrs(%{"pricing" => @pricing}), scope: scope)

      assert changeset.errors[:provider_settings]
    end

    assert {:ok, _} =
             PhoenixKitAI.create_endpoint(attrs(%{"pricing" => @pricing}),
               scope: scope_with(["ai", "ai.manage"])
             )

    assert {:ok, _} = PhoenixKitAI.create_endpoint(attrs(%{"pricing" => @pricing}), scope: owner)
  end

  test "changing or removing a price needs ai.manage", %{owner: owner} do
    endpoint = priced(owner)
    without = scope_with(["ai"])

    for settings <- [%{"pricing" => %{@pricing | "input" => 1}}, %{}] do
      assert {:error, changeset} =
               PhoenixKitAI.update_endpoint(endpoint, %{provider_settings: settings},
                 scope: without
               )

      assert changeset.errors[:provider_settings]
    end

    assert {:ok, updated} =
             PhoenixKitAI.update_endpoint(endpoint, %{provider_settings: %{}}, scope: owner)

    refute Map.has_key?(updated.provider_settings, "pricing")
  end

  test "a change that keeps the price, or a model change that drops it, needs nothing",
       %{owner: owner} do
    endpoint = priced(owner)

    assert {:ok, renamed} =
             PhoenixKitAI.update_endpoint(endpoint, %{name: "Renamed #{endpoint.uuid}"})

    assert renamed.provider_settings["pricing"]

    assert {:ok, moved} = PhoenixKitAI.update_endpoint(renamed, %{model: "glm-4.5"})
    refute Map.has_key?(moved.provider_settings, "pricing")
  end
end
