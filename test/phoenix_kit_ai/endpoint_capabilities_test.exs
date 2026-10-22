defmodule PhoenixKitAI.EndpointCapabilitiesTest do
  @moduledoc """
  Capabilities declared on an endpoint (`provider_settings["capabilities"]`):
  bound to the model they were declared for, dropped when the model changes —
  however the new settings were built — and logged to the activity feed.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Endpoint

  defp endpoint_with_declaration(model, flags) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Declared #{System.unique_integer([:positive])}",
        provider: "mistral",
        base_url: "https://api.mistral.ai/v1",
        model: model,
        api_key: "mistral-test-key",
        provider_settings: %{
          "x_title" => "Kept",
          "capabilities" => Map.put(flags, "model", model)
        }
      })

    endpoint
  end

  describe "a model change" do
    test "drops the declaration and keeps the other settings" do
      endpoint = endpoint_with_declaration("pixtral-large-latest", %{"vision" => "yes"})

      # The endpoint form merges the submitted settings into the stored ones,
      # so the old declaration rides along with the new model.
      {:ok, updated} =
        PhoenixKitAI.update_endpoint(endpoint, %{
          model: "mistral-large-latest",
          provider_settings: endpoint.provider_settings
        })

      assert updated.provider_settings == %{"x_title" => "Kept"}
    end

    test "the same model keeps it" do
      endpoint = endpoint_with_declaration("pixtral-large-latest", %{"vision" => "yes"})

      {:ok, updated} = PhoenixKitAI.update_endpoint(endpoint, %{name: "Renamed #{endpoint.name}"})

      assert updated.provider_settings["capabilities"] == %{
               "model" => "pixtral-large-latest",
               "vision" => "yes"
             }
    end

    test "a declaration naming another model is not stored" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Mismatch #{System.unique_integer([:positive])}",
          provider: "mistral",
          base_url: "https://api.mistral.ai/v1",
          model: "mistral-large-latest",
          api_key: "mistral-test-key",
          provider_settings: %{"capabilities" => %{"model" => "pixtral", "vision" => "yes"}}
        })

      refute Map.has_key?(endpoint.provider_settings, "capabilities")
    end

    test "the changeset drops it while the form is being edited, too" do
      endpoint = endpoint_with_declaration("pixtral-large-latest", %{"vision" => "yes"})
      changeset = PhoenixKitAI.change_endpoint(endpoint, %{"model" => "other-model"})

      refute Map.has_key?(Ecto.Changeset.get_field(changeset, :provider_settings), "capabilities")
      assert %Endpoint{} = Ecto.Changeset.apply_changes(changeset)
    end
  end

  describe "the activity feed" do
    test "a new or changed declaration is logged with its flags" do
      actor_uuid = Ecto.UUID.generate()
      endpoint = endpoint_with_declaration("pixtral-large-latest", %{"vision" => "yes"})

      assert_activity_logged("endpoint.capabilities_declared",
        resource_uuid: endpoint.uuid,
        metadata_has: %{"model" => "pixtral-large-latest", "vision" => "yes"}
      )

      settings =
        Map.put(endpoint.provider_settings, "capabilities", %{
          "model" => "pixtral-large-latest",
          "vision" => "yes",
          "tools" => "yes"
        })

      {:ok, _} =
        PhoenixKitAI.update_endpoint(endpoint, %{provider_settings: settings},
          actor_uuid: actor_uuid
        )

      assert_activity_logged("endpoint.capabilities_declared",
        resource_uuid: endpoint.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"tools" => "yes"}
      )
    end

    test "an update that leaves the declaration as it was logs no declaration" do
      endpoint = endpoint_with_declaration("pixtral-large-latest", %{"vision" => "yes"})
      actor_uuid = Ecto.UUID.generate()

      {:ok, _} =
        PhoenixKitAI.update_endpoint(endpoint, %{name: "Renamed #{endpoint.name}"},
          actor_uuid: actor_uuid
        )

      refute_activity_logged("endpoint.capabilities_declared", actor_uuid: actor_uuid)
    end

    test "an endpoint without a declaration logs none" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Plain #{System.unique_integer([:positive])}",
          provider: "openrouter",
          model: "openai/gpt-4o-mini",
          api_key: "sk-or-v1-test-key"
        })

      refute_activity_logged("endpoint.capabilities_declared", resource_uuid: endpoint.uuid)
    end
  end
end
