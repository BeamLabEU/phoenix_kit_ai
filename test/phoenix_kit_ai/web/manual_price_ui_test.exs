defmodule PhoenixKitAI.Web.ManualPriceUITest do
  @moduledoc """
  The manual price where people see it: two fields on the endpoint form —
  only while the catalogue gives no price — read with the module's money
  parser into `provider_settings["pricing"]`; the «entered by hand» mark on
  a usage row whose cost came from it; and the same mark in the
  recommendations, which also rank a plain list's model by it.
  """

  use PhoenixKitAI.LiveCase

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.{Capabilities, Recommendations, Request}
  alias PhoenixKitAI.Test.FakeAITasks
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  @price "#endpoint-manual-price"

  # A Mistral endpoint whose connection has no key: the edit page fetches
  # nothing, and no catalogue gives the model a price.
  defp unpriced_endpoint(provider_settings \\ %{}) do
    %{uuid: integration_uuid} =
      seed_mistral_connection("price-#{System.unique_integer([:positive])}")

    priced_fixture(
      provider: "mistral",
      base_url: "https://api.mistral.ai/v1",
      model: "glm-4.6",
      integration_uuid: integration_uuid,
      provider_settings: provider_settings
    )
  end

  # An endpoint created by the Owner: a manual price needs ai.manage.
  defp priced_fixture(attrs) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Priced #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "anthropic/claude-3-haiku",
            api_key: "sk-or-v1-test-key"
          },
          Map.new(attrs)
        ),
        scope: Process.get(:owner_scope)
      )

    endpoint
  end

  defp save(view, endpoint, pricing) do
    view
    |> form("#ai-endpoint-form",
      endpoint: %{name: endpoint.name, provider_settings: %{"pricing" => pricing}}
    )
    |> render_submit()
  end

  describe "the endpoint form" do
    # The first user registered is the Owner, who may set a price.
    setup %{conn: conn} do
      owner = Scope.for_user(Fixtures.user_fixture())
      Process.put(:owner_scope, owner)
      {:ok, conn: put_test_scope(conn, owner)}
    end

    test "without ai.manage the price is shown, cannot be edited, and a save keeps it",
         %{conn: conn} do
      endpoint = unpriced_endpoint(%{"pricing" => %{"input" => "0.60", "output" => "2.20"}})

      :ok = ModuleRegistry.register(PhoenixKitAI)
      on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)
      user = Fixtures.user_fixture()
      {:ok, role} = Roles.create_role(%{name: "Role #{System.unique_integer([:positive])}"})
      {:ok, _} = Roles.assign_role(user, role.name)
      :ok = Permissions.set_permissions(role.uuid, ["ai"])

      {:ok, view, _html} =
        conn
        |> put_test_scope(Scope.for_user(user))
        |> live("/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#endpoint-manual-price-locked", "0.6")
      refute has_element?(view, "#{@price} input[name$='[input]']")

      view
      |> form("#ai-endpoint-form", endpoint: %{name: "Renamed #{endpoint.name}"})
      |> render_submit()

      assert %{"input" => "0.60"} =
               PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings["pricing"]
    end

    test "offers the two price fields for a model the catalogue gives no price", %{conn: conn} do
      endpoint = unpriced_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(
               view,
               "#{@price} input[name='endpoint[provider_settings][pricing][input]']"
             )

      assert has_element?(
               view,
               "#{@price} input[name='endpoint[provider_settings][pricing][output]']"
             )
    end

    test "stores the dollars per 1M tokens as dollar strings", %{conn: conn} do
      endpoint = unpriced_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      save(view, endpoint, %{"input" => "0.60", "output" => "2.20"})

      assert PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings["pricing"] == %{
               "model" => "glm-4.6",
               "input" => "0.60",
               "output" => "2.20"
             }
    end

    test "shows the stored price in dollars", %{conn: conn} do
      endpoint = unpriced_endpoint(%{"pricing" => %{"input" => "0.60", "output" => "2.20"}})
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#{@price} input[name$='[input]'][value='0.6']")
      assert has_element?(view, "#{@price} input[name$='[output]'][value='2.2']")
    end

    test "refuses NaN, infinity and a negative price, and saves nothing", %{conn: conn} do
      endpoint = unpriced_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      for bad <- ["NaN", "inf", "-1"] do
        html = save(view, endpoint, %{"input" => bad, "output" => "1"})
        assert html =~ "Enter a price in dollars", bad
      end

      refute Map.has_key?(PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings, "pricing")
    end

    test "half a price is refused, and nothing is saved", %{conn: conn} do
      endpoint = unpriced_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      for half <- [%{"input" => "0.60", "output" => ""}, %{"input" => "", "output" => "2.20"}] do
        html = save(view, endpoint, half)
        assert html =~ "Enter both prices, or leave both empty", inspect(half)
      end

      refute Map.has_key?(PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings, "pricing")
    end

    test "a stored price stays visible and removable when the catalogue prices the model",
         %{conn: conn} do
      stub = Module.concat(__MODULE__, "CatStub#{System.unique_integer([:positive])}")
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "v/priced",
              "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
              "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]}
            }
          ]
        })
      end)

      # Connected without a key: the edit page opens the model section and
      # fetches nothing.
      %{uuid: integration_uuid} =
        seed_openrouter_connection("cat-#{System.unique_integer([:positive])}",
          data: %{"status" => "connected"}
        )

      endpoint =
        priced_fixture(
          model: "v/priced",
          integration_uuid: integration_uuid,
          provider_settings: %{"pricing" => %{"input" => "0.60", "output" => "2.20"}}
        )

      # The catalogue is read with this endpoint's key.
      fixture_endpoint(model: "v/priced")

      pid =
        start_supervised!(
          {Capabilities,
           [initial_refresh: :never, refresh_interval: :infinity, retry_backoff: []]}
        )

      Req.Test.allow(stub, self(), pid)
      assert :ok = Capabilities.refresh()

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#{@price} input[name$='[input]'][value='0.6']")
      assert has_element?(view, "#{@price} [data-catalogue-price-wins]")

      save(view, endpoint, %{"input" => "", "output" => ""})
      refute Map.has_key?(PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings, "pricing")
    end

    test "emptied fields remove the price", %{conn: conn} do
      endpoint = unpriced_endpoint(%{"pricing" => %{"input" => "0.60", "output" => "2.20"}})
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      save(view, endpoint, %{"input" => "", "output" => ""})

      refute Map.has_key?(PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings, "pricing")
    end

    test "has no price fields when the catalogue gives the model a price", %{conn: conn} do
      stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
      Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "v/priced",
              "name" => "Priced",
              "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000004"},
              "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]}
            }
          ]
        })
      end)

      name = "priced-#{System.unique_integer([:positive])}"
      %{uuid: uuid} = seed_openrouter_connection(name)
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      Req.Test.allow(stub, self(), view.pid)
      render_hook(view, "select_provider_connection", %{"uuid" => uuid})
      seed_openrouter_connection(name, data: %{"api_key" => "sk-test"})
      send(view.pid, {:validation_done, uuid, :ok})
      render_async(view, 2_000)

      view |> element("button[phx-value-model='v/priced']") |> render_click()

      refute has_element?(view, @price)
    end
  end

  describe "the usage tab" do
    test "marks a cost computed from a manual price", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      TestRepo.insert!(%Request{
        model: "glm-4.6",
        status: "success",
        request_type: "chat",
        cost: Decimal.new("0.0017"),
        metadata: %{"cost_source" => "manual"},
        inserted_at: now,
        updated_at: now
      })

      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      assert has_element?(view, "[data-cost-source=manual]", "entered by hand")
    end

    test "marks a cost from the built-in price table", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      TestRepo.insert!(%Request{
        model: "claude-sonnet-5-5",
        status: "success",
        request_type: "chat",
        cost: Decimal.new("0.007"),
        metadata: %{"cost_source" => "table"},
        inserted_at: now,
        updated_at: now
      })

      {:ok, view, _html} = live(conn, "/en/admin/ai/usage")

      assert has_element?(view, "[data-cost-source=table]", "list price")
      refute has_element?(view, "[data-cost-source=manual]")
    end
  end

  describe "the recommendations" do
    setup do
      :ok = ModuleRegistry.register(FakeAITasks)
      on_exit(fn -> ModuleRegistry.unregister(FakeAITasks) end)
      :ok
    end

    test "a plain model with a manual price is priced by it and says so" do
      catalogue = [
        %{
          base_url: "https://api.z.ai/api/paas/v4",
          kind: :plain,
          provider: "zai",
          integration_uuid: nil,
          manual_prices: %{
            "glm-4.6" => %{"input" => Decimal.new("0.60"), "output" => Decimal.new("2.20")}
          },
          models: [{"glm-4.6", %Capabilities{}}, {"glm-4.5", %Capabilities{}}]
        }
      ]

      # test.sized declares 10 000 input and 1 000 output tokens.
      recs = Recommendations.ranked("test.sized", catalogue: catalogue, limit: 10)
      row = Enum.find(recs.possible, &(&1.model == "glm-4.6"))

      assert :manual_price in row.notes
      refute :cost_not_reported in row.notes
      assert_in_delta row.price_per_call, 10_000 * 0.6e-6 + 1_000 * 2.2e-6, 1.0e-12

      other = Enum.find(recs.possible, &(&1.model == "glm-4.5"))
      refute :manual_price in other.notes
      assert other.price_per_call == nil
    end

    test "an Anthropic model is priced by the table, marked, and a manual price wins over it" do
      source = fn manual_prices ->
        %{
          base_url: "https://api.anthropic.com/v1",
          kind: :anthropic,
          provider: "anthropic",
          integration_uuid: nil,
          manual_prices: manual_prices,
          models: [{"claude-sonnet-5-5", %Capabilities{text_output: true}}]
        }
      end

      [row] = Recommendations.ranked("test.sized", catalogue: [source.(%{})], limit: 10).possible
      assert :table_price in row.notes
      refute :cost_not_reported in row.notes
      # $2 and $10 per 1M: 10 000 in, 1 000 out.
      assert_in_delta row.price_per_call, 10_000 * 2.0e-6 + 1_000 * 10.0e-6, 1.0e-12

      manual = %{"claude-sonnet-5-5" => %{"input" => Decimal.new(1), "output" => Decimal.new(1)}}

      [row] =
        Recommendations.ranked("test.sized", catalogue: [source.(manual)], limit: 10).possible

      assert :manual_price in row.notes
      refute :table_price in row.notes
      assert_in_delta row.price_per_call, 11_000 * 1.0e-6, 1.0e-12
    end

    test "a model that worked with manual costs says so", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      TestRepo.insert!(%Request{
        model: "glm-4.6",
        status: "success",
        request_type: "chat",
        cost: Decimal.new("0.0017"),
        metadata: %{"task" => "test.sized", "cost_source" => "manual"},
        inserted_at: now,
        updated_at: now
      })

      assert [%{model: "glm-4.6", notes: notes}] = Recommendations.worked("test.sized")
      assert :manual_price in notes

      {:ok, view, _html} = live(conn, "/en/admin/ai/tasks")

      assert has_element?(
               view,
               "[data-task-key='test.sized'] [data-worked-model='glm-4.6'] [data-note=manual_price]",
               "price entered by hand"
             )
    end
  end
end
