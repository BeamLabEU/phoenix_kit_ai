defmodule PhoenixKitAI.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available.

  ## Example

      defmodule PhoenixKitAI.Web.EndpointsTest do
        use PhoenixKitAI.LiveCase

        test "renders endpoints list", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
          assert html =~ "Endpoints"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitAI.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitAI.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Enable the AI module so LiveView mounts don't redirect away.
    # Core's `Settings.update_boolean_setting_with_module/3` writes to
    # the `phoenix_kit_settings` table we create in the test migration.
    PhoenixKitAI.enable_system()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Insert a minimal endpoint for tests that just need a resource to
  point at. `name` is randomised to avoid unique-constraint collisions
  across parallel tests. Accepts a map or keyword list of overrides.
  """
  def fixture_endpoint(attrs \\ %{}) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{
            name: "Test Endpoint #{System.unique_integer([:positive])}",
            provider: "openrouter",
            model: "anthropic/claude-3-haiku",
            api_key: "sk-or-v1-test-key"
          },
          Map.new(attrs)
        )
      )

    endpoint
  end

  @doc """
  Insert a minimal prompt with a unique name. Accepts a map or keyword
  list of overrides.
  """
  def fixture_prompt(attrs \\ %{}) do
    {:ok, prompt} =
      PhoenixKitAI.create_prompt(
        Map.merge(
          %{
            name: "Test Prompt #{System.unique_integer([:positive])}",
            content: "Hello {{Name}}!"
          },
          Map.new(attrs)
        )
      )

    prompt
  end
end
