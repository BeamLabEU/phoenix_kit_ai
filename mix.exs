defmodule PhoenixKitAI.MixProject do
  use Mix.Project

  @version "0.14.1"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_ai"

  def project do
    [
      app: :phoenix_kit_ai,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "AI module for PhoenixKit — endpoints, prompts, completions, and usage tracking",
      package: package(),

      # Coverage — filter test-support modules out of the percentage so
      # the report reflects production code only. Test infra exists for
      # the test suite's own setup, not for production behaviour. See
      # workspace AGENTS.md "Coverage push pattern".
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitAI\.Test\./,
          PhoenixKitAI.DataCase,
          PhoenixKitAI.LiveCase,
          PhoenixKitAI.ActivityLogAssertions,
          ~r/^Jason\.Encoder\./
        ]
      ],

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitAI",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      # 1.7.155+ required: the provider list is built from
      # PhoenixKit.Integrations.Providers.with_capability/1 and base_url/1
      # (capability-driven discovery). Also relies on PhoenixKit.Utils.{Reorder,
      # Values,Format} and the <.form_section> / :sort_bar core components.
      # 1.7.184+ required: `disabled`/`wrapper_class`/`title`/`:description`
      # attrs on <.checkbox> (PhoenixKitWeb.Components.Core.Checkbox).
      # 1.7.194+ required: xAI provider declares the `:realtime_voice`
      # capability that gates the streaming-voice Playground panel — an
      # older core would just never show the panel (silent no-op, not a
      # crash), so this floor is what actually guarantees the feature works.
      pk_dep(:phoenix_kit, ">= 1.7.196"),

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.1"},

      # xAI realtime voice (WebSocket streaming TTS) — the one xAI capability
      # unreachable through the shared REST completions path. Only uses
      # Xai.Realtime, so we deliberately do NOT add {:gun, ...} or
      # {:mint, ...} here — xai >= 0.2 makes both optional adapters for
      # its gRPC parts (Xai.Chat/Xai.Video, which we never call), so
      # neither gun nor its cowlib CVE exposure end up in this dependency
      # tree at all.
      {:xai, "~> 0.2"},

      # Optional rustler pin so the transitive `mdex_native` NIF (via phoenix_kit,
      # a test dependency) can source-build on hosts where its precompiled variant
      # doesn't match the local NIF version.
      {:rustler, ">= 0.0.0", optional: true},

      # Optional: add ex_doc for generating documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # LiveView test rendering
      {:lazy_html, ">= 0.1.0", only: :test},

      # Mocking Xai.RealtimeBehaviour in PhoenixKitAI.Realtime.Session tests
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitAI",
      source_ref: "v#{@version}"
    ]
  end
end
