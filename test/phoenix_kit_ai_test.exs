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
      assert version == "0.1.3"
    end
  end

  describe "css_sources/0" do
    test "returns list with OTP app name" do
      assert PhoenixKitAI.css_sources() == [:phoenix_kit_ai]
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

    test "children/0 returns empty list" do
      assert PhoenixKitAI.children() == []
    end
  end
end
