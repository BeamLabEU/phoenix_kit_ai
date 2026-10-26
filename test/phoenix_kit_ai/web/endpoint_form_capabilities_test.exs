defmodule PhoenixKitAI.Web.EndpointFormCapabilitiesTest do
  @moduledoc """
  What the endpoint form shows about a model's capabilities: badges on the
  model cards, a multimodal chat model in the chat list, the lifecycle of an
  Anthropic model, the checkboxes that declare capabilities for a model the
  catalogue says nothing about, and a declaration the catalogue contradicts.

  Model lists come from a `Req.Test` stub; the validation the form runs
  before fetching is delivered by the test (as in
  `EndpointFormModelFetchTest`), so nothing goes over the network.
  """

  use PhoenixKitAI.LiveCase

  @moduletag :capture_log

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAI.Guard

  @api_key "sk-or-v1-canary-key-0123456789abcdef"

  @openrouter_models [
    %{
      "id" => "~google/gemini-flash-latest",
      "name" => "Gemini Flash Latest",
      "context_length" => 1_048_576,
      "architecture" => %{
        "modality" => "text+image+file+audio+video->text",
        "input_modalities" => ["text", "image", "video", "file", "audio"],
        "output_modalities" => ["text"]
      },
      "supported_parameters" => ["tools", "response_format", "structured_outputs"]
    },
    %{
      "id" => "~deepseek/deepseek-v4-flash-latest",
      "name" => "DeepSeek V4 Flash Latest",
      "context_length" => 163_840,
      "architecture" => %{"input_modalities" => ["text"], "output_modalities" => ["text"]},
      "supported_parameters" => ["tools", "response_format"]
    }
  ]

  setup do
    stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    {:ok, stub: stub}
  end

  # A connection with no key is picked (so the form starts no validation of
  # its own), then given one, and the test delivers the validation result.
  defp load_models(view, stub, uuid, name, provider) do
    Req.Test.allow(stub, self(), view.pid)
    seed(provider, name, data: %{"api_key" => @api_key})
    send(view.pid, {:validation_done, uuid, :ok})
    render_async(view, 2_000)
  end

  defp seed("openrouter", name, opts), do: seed_openrouter_connection(name, opts)
  defp seed("mistral", name, opts), do: seed_mistral_connection(name, opts)

  defp new_form_with_models(conn, stub, models) do
    Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => models}))
    name = "caps-#{System.unique_integer([:positive])}"
    %{uuid: uuid} = seed_openrouter_connection(name)

    {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
    render_hook(view, "select_provider_connection", %{"uuid" => uuid})
    html = load_models(view, stub, uuid, name, "openrouter")
    {view, html}
  end

  defp card(model_id), do: ~s([data-model-card="#{model_id}"])

  describe "model cards" do
    test "a model that takes images is in the chat list with the images badge", %{
      conn: conn,
      stub: stub
    } do
      {view, _html} = new_form_with_models(conn, stub, @openrouter_models)
      render_change(view, "select_provider", %{"provider" => "~google"})

      assert has_element?(view, card("~google/gemini-flash-latest"))

      assert has_element?(
               view,
               card("~google/gemini-flash-latest") <> ~s( [data-capability="vision"])
             )

      assert has_element?(
               view,
               card("~google/gemini-flash-latest") <> ~s( [data-capability="tools"])
             )

      assert has_element?(
               view,
               card("~google/gemini-flash-latest") <> ~s( [data-capability="json_schema"])
             )
    end

    test "a text-only model has no images badge", %{conn: conn, stub: stub} do
      {view, _html} = new_form_with_models(conn, stub, @openrouter_models)
      render_change(view, "select_provider", %{"provider" => "~deepseek"})

      assert has_element?(view, card("~deepseek/deepseek-v4-flash-latest"))

      refute has_element?(
               view,
               card("~deepseek/deepseek-v4-flash-latest") <> ~s( [data-capability="vision"])
             )

      assert has_element?(
               view,
               card("~deepseek/deepseek-v4-flash-latest") <> ~s( [data-capability="tools"])
             )
    end

    test "a provider that reports nothing shows one unknown badge", %{conn: conn, stub: stub} do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => [%{"id" => "mistral-large-latest"}]}))
      name = "caps-#{System.unique_integer([:positive])}"
      %{uuid: uuid} = seed_mistral_connection(name)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")
      render_change(view, "validate", %{"endpoint" => %{"provider" => "mistral"}})
      render_hook(view, "select_provider_connection", %{"uuid" => uuid})
      load_models(view, stub, uuid, name, "mistral")

      assert has_element?(view, card("mistral-large-latest") <> ~s( [data-capability="unknown"]))
      refute has_element?(view, card("mistral-large-latest") <> ~s( [data-capability="vision"]))
    end
  end

  describe "declared capabilities" do
    # An endpoint on a provider with no catalogue, its connection without a
    # key so the edit page fetches nothing: the saved model is shown as is.
    defp mistral_endpoint(provider_settings \\ %{}) do
      %{uuid: integration_uuid} =
        seed_mistral_connection("decl-#{System.unique_integer([:positive])}")

      fixture_endpoint(
        provider: "mistral",
        base_url: "https://api.mistral.ai/v1",
        model: "pixtral-large-latest",
        integration_uuid: integration_uuid,
        provider_settings: provider_settings
      )
    end

    test "can be ticked for a model the catalogue says nothing about, and are saved", %{
      conn: conn
    } do
      endpoint = mistral_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#endpoint-declared-capabilities")
      assert has_element?(view, "#endpoint-declare-vision")
      assert has_element?(view, "#endpoint-declare-tools")
      assert has_element?(view, "#endpoint-declare-json_schema")

      view
      |> form("form[phx-submit=\"save\"]",
        endpoint: %{
          name: endpoint.name,
          provider_settings: %{"capabilities" => %{"vision" => "true", "tools" => "false"}}
        }
      )
      |> render_submit()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)

      assert reloaded.provider_settings["capabilities"] == %{
               "model" => "pixtral-large-latest",
               "vision" => "yes"
             }

      assert_activity_logged("endpoint.capabilities_declared",
        resource_uuid: endpoint.uuid,
        metadata_has: %{"vision" => "yes"}
      )
    end

    test "documents and image generation are declared like the other capabilities", %{
      conn: conn
    } do
      endpoint = mistral_endpoint()
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#endpoint-declare-file_input")
      assert has_element?(view, "#endpoint-declare-image_output")

      view
      |> form("form[phx-submit=\"save\"]",
        endpoint: %{
          name: endpoint.name,
          provider_settings: %{
            "capabilities" => %{"file_input" => "true", "image_output" => "true"}
          }
        }
      )
      |> render_submit()

      assert PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings["capabilities"] == %{
               "model" => "pixtral-large-latest",
               "file_input" => "yes",
               "image_output" => "yes"
             }
    end

    test "a stored declaration shows ticked; unticking everything removes it", %{conn: conn} do
      endpoint =
        mistral_endpoint(%{
          "capabilities" => %{"model" => "pixtral-large-latest", "vision" => "yes"}
        })

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      assert has_element?(view, "#endpoint-declare-vision[checked]")
      refute has_element?(view, "#endpoint-declare-tools[checked]")

      view
      |> form("form[phx-submit=\"save\"]",
        endpoint: %{
          name: endpoint.name,
          provider_settings: %{"capabilities" => %{"vision" => "false"}}
        }
      )
      |> render_submit()

      refute Map.has_key?(
               PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings,
               "capabilities"
             )
    end

    test "with only verified models allowed, a person without ai.manage sees the declaration and keeps it on save",
         %{conn: conn} do
      endpoint =
        mistral_endpoint(%{
          "capabilities" => %{"model" => "pixtral-large-latest", "vision" => "yes"}
        })

      {:ok, _} =
        Settings.update_boolean_setting_with_module(
          Guard.verified_only_setting(),
          true,
          "ai"
        )

      ModuleRegistry.register(PhoenixKitAI)
      on_exit(fn -> ModuleRegistry.unregister(PhoenixKitAI) end)
      _owner = Fixtures.user_fixture()
      user = Fixtures.user_fixture()
      {:ok, _} = Roles.assign_role(user, "Admin")
      %{uuid: role} = Roles.get_role_by_name("Admin")
      :ok = Permissions.set_permissions(role, ["ai", "ai.manage_endpoints"])

      {:ok, view, _html} =
        conn
        |> put_test_scope(Scope.for_user(user))
        |> live("/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#endpoint-declare-locked", "Images")
      refute has_element?(view, "#endpoint-declare-vision")

      view
      |> form("form[phx-submit=\"save\"]", endpoint: %{name: "Renamed #{endpoint.name}"})
      |> render_submit()

      assert %{"vision" => "yes"} =
               PhoenixKitAI.get_endpoint!(endpoint.uuid).provider_settings["capabilities"]

      # Holding ai.manage, the checkboxes are back.
      :ok = Permissions.set_permissions(role, ["ai", "ai.manage", "ai.manage_endpoints"])

      {:ok, view, _html} =
        conn
        |> put_test_scope(Scope.for_user(user))
        |> live("/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert has_element?(view, "#endpoint-declare-vision[checked]")
    end

    test "a model change in the form drops the declaration of the old model", %{conn: conn} do
      endpoint =
        mistral_endpoint(%{
          "capabilities" => %{"model" => "pixtral-large-latest", "vision" => "yes"}
        })

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      render_hook(view, "set_manual_model", %{"model" => "mistral-large-latest"})

      # The checkboxes now speak for the new model, which has nothing declared.
      refute has_element?(view, "#endpoint-declare-vision[checked]")

      view
      |> form("form[phx-submit=\"save\"]", endpoint: %{name: endpoint.name})
      |> render_submit()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.model == "mistral-large-latest"
      refute Map.has_key?(reloaded.provider_settings, "capabilities")
    end

    test "are not offered where the catalogue knows the answer", %{conn: conn, stub: stub} do
      {view, _html} = new_form_with_models(conn, stub, @openrouter_models)
      render_change(view, "select_provider", %{"provider" => "~google"})
      render_click(view, "select_model", %{"model" => "~google/gemini-flash-latest"})

      refute has_element?(view, "#endpoint-declared-capabilities")
    end

    test "a declaration the catalogue contradicts is shown as a conflict", %{
      conn: conn,
      stub: stub
    } do
      Req.Test.stub(stub, &Req.Test.json(&1, %{"data" => @openrouter_models}))
      name = "conflict-#{System.unique_integer([:positive])}"
      %{uuid: integration_uuid} = seed_openrouter_connection(name)

      endpoint =
        fixture_endpoint(
          model: "~deepseek/deepseek-v4-flash-latest",
          integration_uuid: integration_uuid,
          provider_settings: %{
            "capabilities" => %{
              "model" => "~deepseek/deepseek-v4-flash-latest",
              "vision" => "yes"
            }
          }
        )

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      load_models(view, stub, integration_uuid, name, "openrouter")

      assert has_element?(view, "#endpoint-capability-conflict")
    end
  end

  describe "an Anthropic model" do
    test "shows retiring and retired from its lifecycle", %{conn: conn, stub: stub} do
      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => "claude-old", "display_name" => "Claude Old", "lifecycle" => "deprecated"},
            %{"id" => "claude-gone", "display_name" => "Claude Gone", "lifecycle" => "retired"},
            %{"id" => "claude-new", "display_name" => "Claude New", "lifecycle" => "active"}
          ],
          "has_more" => false
        })
      end)

      # The core this suite runs on may not know an `anthropic` provider, so
      # the connection is an OpenRouter one; the endpoint's provider and base
      # URL are what make the form read Anthropic's catalogue.
      name = "anthropic-#{System.unique_integer([:positive])}"
      %{uuid: integration_uuid} = seed_openrouter_connection(name)

      endpoint =
        fixture_endpoint(
          provider: "anthropic",
          base_url: "https://api.anthropic.com/v1",
          model: "claude-old",
          integration_uuid: integration_uuid
        )

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      load_models(view, stub, integration_uuid, name, "openrouter")

      assert has_element?(view, card("claude-old") <> ~s( [data-lifecycle="deprecated"]))
      assert has_element?(view, card("claude-gone") <> ~s( [data-lifecycle="retired"]))
      refute has_element?(view, card("claude-new") <> " [data-lifecycle]")
    end

    test "its card shows what the catalogue says it reads, and no price it does not give", %{
      conn: conn,
      stub: stub
    } do
      Req.Test.stub(stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "claude-reads",
              "display_name" => "Claude Reads",
              "capabilities" => %{
                "image_input" => %{"supported" => true},
                "pdf_input" => %{"supported" => true}
              }
            }
          ],
          "has_more" => false
        })
      end)

      name = "anthropic-#{System.unique_integer([:positive])}"
      %{uuid: integration_uuid} = seed_openrouter_connection(name)

      endpoint =
        fixture_endpoint(
          provider: "anthropic",
          base_url: "https://api.anthropic.com/v1",
          model: "claude-reads",
          integration_uuid: integration_uuid
        )

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      load_models(view, stub, integration_uuid, name, "openrouter")

      assert has_element?(view, card("claude-reads") <> ~s( [data-capability="vision"]))
      assert has_element?(view, card("claude-reads") <> ~s( [data-capability="file_input"]))
      refute has_element?(view, card("claude-reads"), "/M in")
      refute has_element?(view, card("claude-reads"), "$0.00")
    end
  end
end
