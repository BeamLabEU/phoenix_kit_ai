defmodule PhoenixKitAITest do
  use ExUnit.Case

  # These tests verify that the module correctly implements the
  # PhoenixKit.Module behaviour.

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitAI.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitAI.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns a non-empty string" do
      key = PhoenixKitAI.module_key()
      assert is_binary(key)
      assert key == "ai"
    end

    test "module_name/0 returns a non-empty string" do
      name = PhoenixKitAI.module_name()
      assert is_binary(name)
      assert name == "AI"
    end

    test "enabled?/0 returns a boolean" do
      # In test env without DB, this returns false (the rescue fallback)
      assert is_boolean(PhoenixKitAI.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitAI, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitAI, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitAI.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitAI.permission_metadata()
      assert meta.key == PhoenixKitAI.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitAI.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = PhoenixKitAI.admin_tabs()
      assert is_list(tabs)
      assert length(tabs) == 5
    end

    test "parent tab has required fields" do
      [parent | _] = PhoenixKitAI.admin_tabs()
      assert parent.id == :admin_ai
      assert parent.label == "AI"
      assert is_binary(parent.path)
      assert parent.level == :admin
      assert parent.permission == PhoenixKitAI.module_key()
      assert parent.group == :admin_modules
    end

    test "subtabs reference parent" do
      [_parent | subtabs] = PhoenixKitAI.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == :admin_ai
        assert tab.permission == PhoenixKitAI.module_key()
      end
    end

    test "subtabs do not use live_view (routes handled by route_module)" do
      [_parent | subtabs] = PhoenixKitAI.admin_tabs()

      for tab <- subtabs do
        assert is_nil(tab.live_view),
               "Tab #{tab.id} should not have live_view — routes come from PhoenixKitAI.Routes"
      end
    end

    test "paths use hyphens not underscores" do
      for tab <- PhoenixKitAI.admin_tabs() do
        refute String.contains?(tab.path, "_"),
               "Tab #{tab.id} path contains underscores: #{tab.path}"
      end
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = PhoenixKitAI.version()
      assert is_binary(version)
      assert version == "0.13.0"
    end
  end

  describe "css_sources/0" do
    test "returns list with OTP app name" do
      assert PhoenixKitAI.css_sources() == [:phoenix_kit_ai]
    end
  end

  describe "js_sources/0" do
    test "declares the phoenix_kit_ai hook bundle" do
      assert [%{app: :phoenix_kit_ai, file: file, global: "PhoenixKitAIHooks"}] =
               PhoenixKitAI.js_sources()

      assert file == "static/assets/phoenix_kit_ai.js"
    end

    test "every declared bundle file exists under this app's priv/" do
      for %{app: app, file: file} <- PhoenixKitAI.js_sources() do
        path = Path.join(:code.priv_dir(app), file)
        assert File.exists?(path), "js_sources/0 declares #{file}, but #{path} does not exist"
      end
    end

    # Regression: 0.12.0 declared this bundle via js_sources/0 but omitted
    # `priv` from `package[:files]` in mix.exs, so it existed in this repo
    # (this test would have passed) yet never shipped in the published Hex
    # tarball — any host consuming it from Hex hit `js_sources/0 bundle not
    # found` at compile time. `File.exists?/1` above can't catch a packaging
    # omission (the file is always present in a local checkout); only
    # checking the actual package allowlist can.
    test "mix.exs package files include priv (so js_sources bundles actually ship on Hex)" do
      # `package/0` is private in mix.exs — read it back from the project
      # config instead of calling it directly.
      files = Mix.Project.config()[:package][:files] || []

      assert "priv" in files,
             "mix.exs package[:files] must include \"priv\" or js_sources/0 bundles won't ship on Hex"
    end
  end

  describe "children/0" do
    test "starts the realtime session DynamicSupervisor" do
      assert [{DynamicSupervisor, name: PhoenixKitAI.Realtime.Supervisor, strategy: :one_for_one}] =
               PhoenixKitAI.children()
    end
  end

  describe "route_module/0" do
    test "returns the routes module" do
      assert PhoenixKitAI.route_module() == PhoenixKitAI.Routes
    end
  end

  describe "required_integrations/0" do
    test "declares openrouter as required" do
      assert PhoenixKitAI.required_integrations() == ["openrouter"]
    end
  end

  describe "optional callbacks have defaults" do
    test "get_config/0 returns a map" do
      config = PhoenixKitAI.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :enabled)
    end

    test "settings_tabs/0 returns empty list" do
      assert PhoenixKitAI.settings_tabs() == []
    end

    test "user_dashboard_tabs/0 returns empty list" do
      assert PhoenixKitAI.user_dashboard_tabs() == []
    end
  end
end
