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
      import PhoenixKitAI.ActivityLogAssertions
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
  Build a fake scope struct for tests that need an authenticated actor.

  The returned scope mirrors the production shape (`%PhoenixKit.Users.Auth.Scope{}`
  with a real `%User{}` struct) so the LV's `actor_opts/1` matches on
  `phoenix_kit_current_user.uuid` and threads `actor_uuid:` through to
  the activity log.

  ## Example

      conn = put_test_scope(build_conn(), fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/ai/endpoints")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")

    user = %{uuid: user_uuid, email: email}

    %{
      user: user,
      authenticated?: true,
      cached_roles: ["Owner", "Admin"]
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
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
  Seed an OpenRouter integration connection in `phoenix_kit_settings` so
  `PhoenixKit.Integrations.list_connections("openrouter")` returns it.
  Returns `%{uuid: setting_uuid, name: connection_name}` — `uuid` is the
  value the endpoint form treats as `active_connection`.

  No `api_key` is included, so `Integrations.connected?/1` stays `false`
  and the LV doesn't trigger a model fetch on mount. Tests that need a
  "connected" connection should pass `data: %{"api_key" => "sk-..."}`.
  """
  def seed_openrouter_connection(name, opts \\ []) when is_binary(name) do
    seed_provider_connection("openrouter", name, opts)
  end

  @doc """
  Seed a Mistral connection — same shape as `seed_openrouter_connection/2`
  but for the `mistral` provider key. Used by tests that assert on the
  Provider-dropdown filter behaviour, which needs ≥1 non-OpenRouter
  connection on the row.
  """
  def seed_mistral_connection(name, opts \\ []) when is_binary(name) do
    seed_provider_connection("mistral", name, opts)
  end

  defp seed_provider_connection(provider, name, opts) do
    extra = Keyword.get(opts, :data, %{})

    full_data =
      Map.merge(
        %{
          "provider" => provider,
          "name" => name,
          "auth_type" => "api_key",
          "status" => "disconnected"
        },
        extra
      )

    {:ok, setting} =
      PhoenixKit.Settings.update_json_setting_with_module(
        "integration:#{provider}:#{name}",
        full_data,
        "integrations"
      )

    %{uuid: setting.uuid, name: name}
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
