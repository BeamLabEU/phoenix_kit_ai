defmodule PhoenixKitAI.EndpointTest do
  # async: false — see comment in prompt_changeset_test.exs
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Endpoint

  describe "changeset/2 — validation" do
    test "requires name and model (provider has a default)" do
      changeset = Endpoint.changeset(%Endpoint{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:name]
      assert errors[:model]
      # provider defaults to "openrouter" from the schema, so validate_required
      # passes even when the caller doesn't provide one.
      refute errors[:provider]
    end

    test "rejects an explicit nil provider" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: nil,
          model: "a/b"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:provider]
    end

    test "accepts a minimal valid endpoint" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "Minimal",
          provider: "openrouter",
          model: "anthropic/claude-3-haiku"
        })

      assert changeset.valid?
    end

    test "rejects temperature outside [0, 2]" do
      too_low =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b",
          temperature: -0.1
        })

      too_high =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b",
          temperature: 2.5
        })

      refute too_low.valid?
      refute too_high.valid?
      assert errors_on(too_low)[:temperature]
      assert errors_on(too_high)[:temperature]
    end

    test "allows an empty api_key (legacy rows) as long as provider is set" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "No key",
          provider: "openrouter",
          model: "a/b",
          api_key: nil
        })

      assert changeset.valid?
    end
  end

  describe "masked_api_key/1" do
    test "returns placeholder for nil and empty string" do
      assert Endpoint.masked_api_key(nil) == "Not set"
      assert Endpoint.masked_api_key("") == "Not set"
    end

    test "preserves the last 4 characters for inspection" do
      assert Endpoint.masked_api_key("sk-or-v1-1234567890abcdef") ==
               String.duplicate("*", 21) <> "cdef"
    end

    test "handles short keys gracefully" do
      # Short keys are masked in full (nothing meaningful to reveal)
      result = Endpoint.masked_api_key("abc")
      assert is_binary(result)
    end
  end

  describe "create_endpoint/2 (integration)" do
    test "inserts a row and returns the struct" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Create Test",
          provider: "openrouter",
          model: "anthropic/claude-3-haiku"
        })

      assert endpoint.uuid
      assert endpoint.name == "Create Test"
      assert endpoint.enabled
      assert endpoint.temperature == 0.7
    end

    test "rejects duplicate names with a changeset error" do
      attrs = %{name: "Dup", provider: "openrouter", model: "a/b"}
      {:ok, _first} = PhoenixKitAI.create_endpoint(attrs)
      {:error, changeset} = PhoenixKitAI.create_endpoint(attrs)

      assert errors_on(changeset)[:name]
    end
  end

  describe "update_endpoint/3 (integration)" do
    test "updates fields and returns the new struct" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Update Test",
          provider: "openrouter",
          model: "a/b"
        })

      {:ok, updated} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 0.2})

      assert updated.temperature == 0.2
    end

    test "returns {:error, changeset} for invalid updates" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Invalid Update",
          provider: "openrouter",
          model: "a/b"
        })

      {:error, changeset} = PhoenixKitAI.update_endpoint(endpoint, %{temperature: 10})

      assert errors_on(changeset)[:temperature]
    end
  end

  describe "delete_endpoint/2 (integration)" do
    test "removes the row" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Delete Test",
          provider: "openrouter",
          model: "a/b"
        })

      {:ok, _} = PhoenixKitAI.delete_endpoint(endpoint)

      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
    end
  end

  describe "resolve_endpoint/1" do
    test "resolves a valid UUID string to the endpoint struct" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Resolve UUID",
          provider: "openrouter",
          model: "a/b"
        })

      assert {:ok, found} = PhoenixKitAI.resolve_endpoint(endpoint.uuid)
      assert found.uuid == endpoint.uuid
    end

    test "returns :endpoint_not_found for a valid but non-existent UUID" do
      uuid = "01234567-89ab-7def-8000-000000000000"
      assert {:error, :endpoint_not_found} = PhoenixKitAI.resolve_endpoint(uuid)
    end

    test "returns :invalid_endpoint_identifier for nonsense input" do
      assert {:error, :invalid_endpoint_identifier} = PhoenixKitAI.resolve_endpoint(123)
      assert {:error, :invalid_endpoint_identifier} = PhoenixKitAI.resolve_endpoint(nil)
    end

    test "accepts an Endpoint struct directly" do
      endpoint = %PhoenixKitAI.Endpoint{uuid: "01234567-89ab-7def-8000-000000000000"}
      assert {:ok, ^endpoint} = PhoenixKitAI.resolve_endpoint(endpoint)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
