defmodule PhoenixKitAI.SchemaCoverageTest do
  @moduledoc """
  Coverage push for the three Ecto schema modules — `Endpoint`,
  `Prompt`, `Request`. Targets the helper functions, formatters, and
  changeset branches not exercised by the existing schema tests.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.{Endpoint, Prompt, Request}

  describe "Endpoint helpers" do
    test "valid_providers/0" do
      assert is_list(Endpoint.valid_providers())
      assert "openrouter" in Endpoint.valid_providers()
    end

    test "provider_options/0" do
      assert [{"OpenRouter", "openrouter"}] = Endpoint.provider_options()
    end

    test "default_base_url/1 — known + unknown provider" do
      assert Endpoint.default_base_url("openrouter") == "https://openrouter.ai/api/v1"
      assert Endpoint.default_base_url("unknown") == nil
    end

    test "provider_label/1 — known + fallback" do
      assert Endpoint.provider_label("openrouter") == "OpenRouter"
      assert Endpoint.provider_label("custom") == "custom"
    end

    test "recently_validated?/1 — nil + recent + stale" do
      refute Endpoint.recently_validated?(%Endpoint{last_validated_at: nil})

      now = DateTime.utc_now()
      assert Endpoint.recently_validated?(%Endpoint{last_validated_at: now})

      stale = DateTime.add(now, -30 * 24 * 3600, :second)
      refute Endpoint.recently_validated?(%Endpoint{last_validated_at: stale})
    end

    test "short_model_name/1 — nil + empty + provider/model + bare" do
      assert Endpoint.short_model_name(nil) == nil
      assert Endpoint.short_model_name("") == nil
      assert Endpoint.short_model_name("anthropic/claude-3-haiku") == "claude-3-haiku"
      assert Endpoint.short_model_name("bare") == "bare"
    end

    test "image_size_options + image_quality_options + reasoning_effort_options" do
      assert is_list(Endpoint.image_size_options())
      assert is_list(Endpoint.image_quality_options())
      effort_values = Endpoint.reasoning_effort_options() |> Enum.map(fn {_, v} -> v end)
      assert "none" in effort_values
      assert "xhigh" in effort_values
    end

    test "validation_changeset/1 stamps last_validated_at" do
      ep = %Endpoint{last_validated_at: nil}
      changeset = Endpoint.validation_changeset(ep)
      assert %Ecto.Changeset{changes: %{last_validated_at: _}} = changeset
    end

    test "masked_api_key/1 — short keys are fully masked" do
      assert Endpoint.masked_api_key("short") == "*****"
      assert Endpoint.masked_api_key("12345678") == "********"
    end

    test "masked_api_key/1 — long keys keep last 4 visible" do
      result = Endpoint.masked_api_key("sk-or-v1-abcdef123456")
      assert String.ends_with?(result, "3456")
      assert String.starts_with?(result, "*")
    end
  end

  describe "Endpoint changeset — penalty + reasoning + base URL" do
    test "rejects frequency_penalty outside [-2, 2]" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               frequency_penalty: 3.0
             }).valid?
    end

    test "rejects top_p outside [0, 1]" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               top_p: 1.5
             }).valid?
    end

    test "rejects unknown reasoning_effort value" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b",
          reasoning_effort: "extreme"
        })

      refute changeset.valid?
      errors = changeset.errors |> Enum.map(fn {f, _} -> f end)
      assert :reasoning_effort in errors
    end

    test "accepts valid reasoning_effort values + empty string" do
      for effort <- ["none", "minimal", "low", "medium", "high", "xhigh", ""] do
        changeset =
          Endpoint.changeset(%Endpoint{}, %{
            name: "X",
            provider: "openrouter",
            model: "a/b",
            reasoning_effort: effort
          })

        assert changeset.valid?, "expected #{inspect(effort)} to validate"
      end
    end

    test "rejects reasoning_max_tokens outside [1024, 32_000]" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b",
          reasoning_max_tokens: 100
        })

      refute changeset.valid?
    end

    test "accepts reasoning_max_tokens within range" do
      assert Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               reasoning_max_tokens: 4096
             }).valid?
    end

    test "rejects http base_url with .local hostname" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://internal.local/api"
             }).valid?
    end

    test "rejects base_url pointing at localhost" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://localhost/api"
             }).valid?
    end

    test "rejects base_url pointing at RFC1918 IP literal" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://10.0.0.1/api"
             }).valid?
    end

    test "rejects base_url pointing at link-local IPv4 (169.254.169.254)" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://169.254.169.254/latest/meta-data/"
             }).valid?
    end

    test "rejects base_url with non-http(s) scheme" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "ftp://example.com/api"
             }).valid?
    end

    test "rejects base_url with no host" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https:///"
             }).valid?
    end

    test "allow_internal_endpoint_urls bypass — accepts loopback when set" do
      Application.put_env(:phoenix_kit_ai, :allow_internal_endpoint_urls, true)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ai, :allow_internal_endpoint_urls)
      end)

      assert Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "http://localhost:11434/api"
             }).valid?
    end

    test "fills default base_url when blank" do
      changeset =
        Endpoint.changeset(%Endpoint{}, %{
          name: "X",
          provider: "openrouter",
          model: "a/b"
        })

      assert Ecto.Changeset.get_change(changeset, :base_url) == "https://openrouter.ai/api/v1"
    end

    test "rejects 172.16-31.x.x as RFC1918" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://172.20.0.5/api"
             }).valid?
    end

    test "rejects 192.168.x.x as RFC1918" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://192.168.1.1/api"
             }).valid?
    end

    test "rejects ::1 IPv6 loopback" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://[::1]/api"
             }).valid?
    end

    test "rejects fc00::/7 IPv6 unique-local" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://[fd00::1]/api"
             }).valid?
    end

    test "rejects fe80::/10 IPv6 link-local" do
      refute Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://[fe80::1]/api"
             }).valid?
    end

    test "accepts a normal public hostname base_url" do
      assert Endpoint.changeset(%Endpoint{}, %{
               name: "X",
               provider: "openrouter",
               model: "a/b",
               base_url: "https://api.example.com/v1"
             }).valid?
    end
  end

  describe "Prompt — render + helpers" do
    test "render_system_prompt/2 nil + empty + with-vars + non-map" do
      assert Prompt.render_system_prompt(%Prompt{system_prompt: nil}, %{}) == {:ok, nil}
      assert Prompt.render_system_prompt(%Prompt{system_prompt: ""}, %{}) == {:ok, nil}

      assert Prompt.render_system_prompt(%Prompt{system_prompt: "You are a {{Role}}"}, %{
               "Role" => "translator"
             }) == {:ok, "You are a translator"}

      assert Prompt.render_system_prompt(%Prompt{system_prompt: "raw"}, :not_a_map) ==
               {:ok, "raw"}
    end

    test "render/2 handles atom keys + non-map fallback" do
      p = %Prompt{content: "Hi {{Name}}"}
      assert {:ok, "Hi You"} = Prompt.render(p, %{Name: "You"})
      assert {:ok, "Hi {{Name}}"} = Prompt.render(p, :not_a_map)
    end

    test "render_content/2 — string + non-map + non-binary" do
      assert {:ok, "x World"} = Prompt.render_content("x {{N}}", %{"N" => "World"})
      assert {:ok, "x {{N}}"} = Prompt.render_content("x {{N}}", :not_a_map)
    end

    test "extract_variables/1 returns [] for non-binary input" do
      assert Prompt.extract_variables(nil) == []
      assert Prompt.extract_variables(123) == []
    end

    test "validate_variables/2 — empty list + missing list + non-map provided" do
      assert :ok = Prompt.validate_variables(%Prompt{variables: []}, %{"X" => 1})
      assert {:error, ["A"]} = Prompt.validate_variables(%Prompt{variables: ["A"]}, %{})
      assert {:error, ["A"]} = Prompt.validate_variables(%Prompt{variables: ["A"]}, :not_a_map)
    end

    test "content_preview/1 — nil + empty + short + long" do
      assert Prompt.content_preview(nil) == ""
      assert Prompt.content_preview("") == ""
      assert Prompt.content_preview("Short content") == "Short content"

      long = String.duplicate("a", 200)
      assert String.ends_with?(Prompt.content_preview(long), "...")
    end

    test "generate_slug/1 — nil + empty + words" do
      assert Prompt.generate_slug(nil) == ""
      assert Prompt.generate_slug("") == ""
      assert Prompt.generate_slug("My Prompt!") =~ ~r/^[a-z0-9-]+$/
    end

    test "variable_regex/0 returns a regex" do
      assert %Regex{} = Prompt.variable_regex()
    end

    test "has_variables?/1 — list + empty list + struct + nil" do
      assert Prompt.has_variables?(%Prompt{variables: ["A"]})
      refute Prompt.has_variables?(%Prompt{variables: []})
      refute Prompt.has_variables?(nil)
    end

    test "variable_count/1 — list + empty + nil" do
      assert Prompt.variable_count(%Prompt{variables: ["A", "B"]}) == 2
      assert Prompt.variable_count(%Prompt{variables: []}) == 0
      assert Prompt.variable_count(nil) == 0
    end

    test "format_variables_for_display/1" do
      assert Prompt.format_variables_for_display(%Prompt{variables: ["A", "B"]}) ==
               "{{A}}, {{B}}"

      assert Prompt.format_variables_for_display(%Prompt{variables: []}) == ""
      assert Prompt.format_variables_for_display(nil) == ""
    end

    test "valid_content?/1 — valid + invalid + non-binary" do
      assert Prompt.valid_content?("Hello {{Name}}")
      refute Prompt.valid_content?("Hello {{1bad}}")
      refute Prompt.valid_content?("Hello {{User Name}}")
      refute Prompt.valid_content?(nil)
    end

    test "invalid_variables/1 returns the bad ones" do
      assert Prompt.invalid_variables("{{User Name}} and {{ok}}") == ["User Name"]
      assert Prompt.invalid_variables("All ok {{X}}") == []
      assert Prompt.invalid_variables(nil) == []
    end

    test "merge_with_defaults/3 fills missing with defaults" do
      p = %Prompt{variables: ["Name", "Age"]}

      assert %{"Name" => "John", "Age" => "Unknown"} =
               Prompt.merge_with_defaults(p, %{"Name" => "John"}, %{"Age" => "Unknown"})
    end

    test "merge_with_defaults/3 fallbacks for non-struct + non-map inputs" do
      assert Prompt.merge_with_defaults(nil, %{"X" => 1}, %{}) == %{"X" => 1}
      assert Prompt.merge_with_defaults(nil, :not_a_map, :not_a_map) == %{}
    end

    test "render/2 falls back to default for unknown variable" do
      p = %Prompt{content: "Missing {{Var}}"}
      assert {:ok, "Missing {{Var}}"} = Prompt.render(p, %{})
    end

    test "render/2 with atom key — handles arbitrary string and atom-existing" do
      p = %Prompt{content: "{{abc}}"}
      assert {:ok, "1"} = Prompt.render(p, %{abc: 1})
    end

    test "usage_changeset/1 increments + stamps when starting from nil" do
      changeset = Prompt.usage_changeset(%Prompt{usage_count: nil})
      assert changeset.changes.usage_count == 1
    end
  end

  describe "Request helpers" do
    test "valid_statuses + valid_request_types" do
      assert "success" in Request.valid_statuses()
      assert "chat" in Request.valid_request_types()
    end

    test "status_label/1 dispatch covers every case" do
      for {status, label} <- [
            {"success", "Success"},
            {"error", "Error"},
            {"timeout", "Timeout"},
            {"weird", "Unknown"}
          ] do
        assert Request.status_label(status) == label
      end
    end

    test "status_color/1 dispatch covers every case" do
      for {status, color} <- [
            {"success", "badge-success"},
            {"error", "badge-error"},
            {"timeout", "badge-warning"},
            {"weird", "badge-neutral"}
          ] do
        assert Request.status_color(status) == color
      end
    end

    test "format_latency/1 — nil + sub-second + multi-second" do
      assert Request.format_latency(nil) == "-"
      assert Request.format_latency(450) == "450ms"
      assert Request.format_latency(2500) == "2.5s"
    end

    test "format_tokens/1 — nil + 0 + small + thousands + millions" do
      assert Request.format_tokens(nil) == "-"
      assert Request.format_tokens(0) == "0"
      assert Request.format_tokens(500) == "500"
      assert Request.format_tokens(2500) == "2.5K"
      assert Request.format_tokens(2_500_000) == "2.5M"
    end

    test "format_cost/1 — nil + zero + dollar + cents + fractional + sub-fractional" do
      assert Request.format_cost(nil) == "-"
      assert Request.format_cost(0) == "$0.00"
      assert Request.format_cost(1_500_000) == "$1.50"
      assert Request.format_cost(50_000) == "$0.05"
      assert Request.format_cost(500) == "$0.0005"
      assert Request.format_cost(50) == "$0.000050"
    end

    test "short_model_name/1 — nil + empty + provider/model + bare + multi-slash" do
      assert Request.short_model_name(nil) == "-"
      assert Request.short_model_name("") == "-"
      assert Request.short_model_name("anthropic/claude-3-haiku") == "claude-3-haiku"
      assert Request.short_model_name("bare") == "bare"
    end

    test "changeset/2 — rejects unknown status + accepts valid status" do
      refute Request.changeset(%Request{}, %{status: "weird"}).valid?
      assert Request.changeset(%Request{}, %{status: "success"}).valid?
    end

    test "changeset/2 rejects negative token counts" do
      changeset =
        Request.changeset(%Request{}, %{
          status: "success",
          input_tokens: -1
        })

      refute changeset.valid?
    end

    test "changeset/2 auto-calculates total_tokens when missing" do
      changeset =
        Request.changeset(%Request{}, %{
          status: "success",
          input_tokens: 10,
          output_tokens: 5
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :total_tokens) == 15
    end
  end
end
