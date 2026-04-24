defmodule PhoenixKitAI.ActivityLoggingTest do
  @moduledoc """
  Pins every activity-log call site introduced in the quality sweep.

  Without these tests, a typoed `action` string, a removed `|>
  log_*_activity(...)` pipe step, or a regression in `actor_opts/1`
  passes silently — the surrounding CRUD test still goes green
  because it only checks DB state, not the activity row.
  """

  # async: false — these tests assert exact-row counts, so the shared
  # phoenix_kit_activities table must be isolated per test.
  use PhoenixKitAI.DataCase, async: false

  describe "endpoint mutations" do
    test "create_endpoint logs `endpoint.created` with name + actor" do
      actor = Ecto.UUID.generate()

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(
          %{
            name: "Activity Test Created",
            provider: "openrouter",
            model: "a/b"
          },
          actor_uuid: actor,
          actor_role: "admin"
        )

      assert_activity_logged("endpoint.created",
        resource_uuid: endpoint.uuid,
        actor_uuid: actor,
        metadata_has: %{"name" => "Activity Test Created", "actor_role" => "admin"}
      )
    end

    test "update_endpoint logs `endpoint.updated`" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "To Update",
          provider: "openrouter",
          model: "a/b"
        })

      actor = Ecto.UUID.generate()
      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 0.2}, actor_uuid: actor)

      assert_activity_logged("endpoint.updated",
        resource_uuid: endpoint.uuid,
        actor_uuid: actor
      )
    end

    test "update_endpoint with enabled flip logs both `endpoint.updated` and `endpoint.disabled`" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Toggle Off",
          provider: "openrouter",
          model: "a/b",
          enabled: true
        })

      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{enabled: false})

      assert_activity_logged("endpoint.updated", resource_uuid: endpoint.uuid)
      assert_activity_logged("endpoint.disabled", resource_uuid: endpoint.uuid)
    end

    test "update_endpoint flipping enabled false→true logs `endpoint.enabled`" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Toggle On",
          provider: "openrouter",
          model: "a/b",
          enabled: false
        })

      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{enabled: true})

      assert_activity_logged("endpoint.enabled", resource_uuid: endpoint.uuid)
      refute_activity_logged("endpoint.disabled", resource_uuid: endpoint.uuid)
    end

    test "update_endpoint without enabled change logs only `endpoint.updated`" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Same State",
          provider: "openrouter",
          model: "a/b",
          enabled: true
        })

      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 0.5})

      assert_activity_logged("endpoint.updated", resource_uuid: endpoint.uuid)
      refute_activity_logged("endpoint.enabled", resource_uuid: endpoint.uuid)
      refute_activity_logged("endpoint.disabled", resource_uuid: endpoint.uuid)
    end

    test "delete_endpoint logs `endpoint.deleted`" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "To Delete",
          provider: "openrouter",
          model: "a/b"
        })

      {:ok, _} = PhoenixKitAI.delete_endpoint(endpoint)

      assert_activity_logged("endpoint.deleted", resource_uuid: endpoint.uuid)
    end

    test "failed update does NOT emit any activity" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Stays Same",
          provider: "openrouter",
          model: "a/b"
        })

      {:error, _changeset} =
        PhoenixKitAI.update_endpoint(endpoint, %{temperature: 99})

      refute_activity_logged("endpoint.updated", resource_uuid: endpoint.uuid)
      refute_activity_logged("endpoint.enabled", resource_uuid: endpoint.uuid)
      refute_activity_logged("endpoint.disabled", resource_uuid: endpoint.uuid)
    end
  end

  describe "prompt mutations" do
    test "create_prompt logs `prompt.created` with name + actor" do
      actor = Ecto.UUID.generate()

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(
          %{name: "Activity Prompt #{System.unique_integer([:positive])}", content: "Hi"},
          actor_uuid: actor,
          actor_role: "user"
        )

      assert_activity_logged("prompt.created",
        resource_uuid: prompt.uuid,
        actor_uuid: actor,
        metadata_has: %{"actor_role" => "user"}
      )
    end

    test "update_prompt logs `prompt.updated`" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Update Prompt #{System.unique_integer([:positive])}",
          content: "Hi"
        })

      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{content: "Hello"})

      assert_activity_logged("prompt.updated", resource_uuid: prompt.uuid)
    end

    test "update_prompt enabled flip logs `prompt.disabled`" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Disable Prompt #{System.unique_integer([:positive])}",
          content: "Hi",
          enabled: true
        })

      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{enabled: false})

      assert_activity_logged("prompt.disabled", resource_uuid: prompt.uuid)
    end

    test "update_prompt enable flip logs `prompt.enabled`" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Enable Prompt #{System.unique_integer([:positive])}",
          content: "Hi",
          enabled: false
        })

      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{enabled: true})

      assert_activity_logged("prompt.enabled", resource_uuid: prompt.uuid)
    end

    test "delete_prompt logs `prompt.deleted`" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Delete Prompt #{System.unique_integer([:positive])}",
          content: "Bye"
        })

      {:ok, _} = PhoenixKitAI.delete_prompt(prompt)

      assert_activity_logged("prompt.deleted", resource_uuid: prompt.uuid)
    end
  end

  describe "actor metadata defaults" do
    test "missing actor_uuid is allowed and serialised as nil" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "No Actor",
          provider: "openrouter",
          model: "a/b"
        })

      row =
        assert_activity_logged("endpoint.created", resource_uuid: endpoint.uuid)

      assert row.actor_uuid in [nil]
    end

    test "actor_role defaults to \"user\" when not passed" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Default Role",
          provider: "openrouter",
          model: "a/b"
        })

      assert_activity_logged("endpoint.created",
        resource_uuid: endpoint.uuid,
        metadata_has: %{"actor_role" => "user"}
      )
    end
  end
end
