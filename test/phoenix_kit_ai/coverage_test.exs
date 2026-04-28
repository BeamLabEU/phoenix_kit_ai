defmodule PhoenixKitAI.CoverageTest do
  @moduledoc """
  Targeted coverage push for the public API surface of `PhoenixKitAI`.

  Each test pins one or more public functions that pre-existing test
  files do not exercise. Pure DB / pure helper paths only — HTTP
  completion paths (`complete/3`, `ask/3`, `embed/3`,
  `ask_with_prompt/4`, `complete_with_system_prompt/5`) are covered in
  `completion_coverage_test.exs` via `Req.Test` stubs.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Endpoint, Prompt, Request}

  defp endpoint_fixture(attrs \\ %{}) do
    base = %{
      name: "EP-#{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "a/b"
    }

    {:ok, ep} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    ep
  end

  defp prompt_fixture(attrs \\ %{}) do
    base = %{
      name: "P-#{System.unique_integer([:positive])}",
      content: "Hello {{Name}}"
    }

    {:ok, p} = PhoenixKitAI.create_prompt(Map.merge(base, attrs))
    p
  end

  defp request_fixture(attrs) do
    base = %{
      status: "success",
      model: "a/b",
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15
    }

    {:ok, r} = PhoenixKitAI.create_request(Map.merge(base, attrs))
    r
  end

  describe "pubsub topics + subscribers" do
    test "endpoints_topic returns the constant string" do
      assert PhoenixKitAI.endpoints_topic() == "phoenix_kit:ai:endpoints"
    end

    test "prompts_topic returns the constant string" do
      assert PhoenixKitAI.prompts_topic() == "phoenix_kit:ai:prompts"
    end

    test "requests_topic returns the constant string" do
      assert PhoenixKitAI.requests_topic() == "phoenix_kit:ai:requests"
    end

    test "subscribe_endpoints + create_endpoint broadcasts :endpoint_created" do
      :ok = PhoenixKitAI.subscribe_endpoints()
      ep = endpoint_fixture()
      assert_receive {:endpoint_created, %Endpoint{uuid: uuid}}, 500
      assert uuid == ep.uuid
    end

    test "subscribe_prompts + update_prompt broadcasts :prompt_updated" do
      prompt = prompt_fixture()
      :ok = PhoenixKitAI.subscribe_prompts()
      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{description: "x"})
      assert_receive {:prompt_updated, %Prompt{uuid: uuid}}, 500
      assert uuid == prompt.uuid
    end

    test "subscribe_requests + create_request broadcasts :request_created" do
      ep = endpoint_fixture()
      :ok = PhoenixKitAI.subscribe_requests()
      _ = request_fixture(%{endpoint_uuid: ep.uuid})
      assert_receive {:request_created, %Request{}}, 500
    end
  end

  describe "module behaviour callbacks" do
    test "module_key/0 + module_name/0 + version/0 are stable" do
      assert PhoenixKitAI.module_key() == "ai"
      assert PhoenixKitAI.module_name() == "AI"
      assert PhoenixKitAI.version() =~ ~r/^\d+\.\d+\.\d+$/
    end

    test "permission_metadata/0 returns the admin tab metadata" do
      meta = PhoenixKitAI.permission_metadata()
      assert meta.key == "ai"
      assert is_binary(meta.label)
      assert is_binary(meta.icon)
    end

    test "admin_tabs/0 returns at least the parent + endpoints + prompts tabs" do
      tabs = PhoenixKitAI.admin_tabs()
      ids = Enum.map(tabs, & &1.id)
      assert :admin_ai in ids
      assert :admin_ai_endpoints in ids
      assert :admin_ai_prompts in ids
      assert :admin_ai_playground in ids
      assert :admin_ai_usage in ids
    end

    test "css_sources/0 returns the OTP app atom" do
      assert PhoenixKitAI.css_sources() == [:phoenix_kit_ai]
    end

    test "required_integrations/0 returns openrouter" do
      assert PhoenixKitAI.required_integrations() == ["openrouter"]
    end

    test "route_module/0 points at PhoenixKitAI.Routes" do
      assert PhoenixKitAI.route_module() == PhoenixKitAI.Routes
    end

    test "get_config/0 returns enabled + counts map" do
      _ = endpoint_fixture()
      config = PhoenixKitAI.get_config()
      assert is_boolean(config.enabled)
      assert config.endpoints_count >= 1
      assert is_integer(config.total_requests)
      assert is_integer(config.total_tokens)
    end
  end

  describe "endpoint listing — sort + filter + paginate" do
    setup do
      ep_high =
        endpoint_fixture(%{name: "High", provider: "openrouter", model: "a/b", sort_order: 1})

      ep_low =
        endpoint_fixture(%{name: "Low", provider: "anthropic", model: "x/y", sort_order: 2})

      r_low =
        request_fixture(%{
          endpoint_uuid: ep_low.uuid,
          total_tokens: 10,
          cost_cents: 5
        })

      r_high1 =
        request_fixture(%{
          endpoint_uuid: ep_high.uuid,
          total_tokens: 100,
          cost_cents: 50
        })

      r_high2 =
        request_fixture(%{
          endpoint_uuid: ep_high.uuid,
          total_tokens: 200,
          cost_cents: 100
        })

      # `Request.timestamps(type: :utc_datetime)` is second-precision, so
      # multiple inserts in the same second collide on `inserted_at`.
      # Stamp explicit times so the :last_used DESC test is deterministic.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      stamp = fn r, secs_ago ->
        ts = DateTime.add(now, -secs_ago, :second)
        uuid = r.uuid

        PhoenixKitAI.Request
        |> Ecto.Query.where([r], r.uuid == ^uuid)
        |> Repo.update_all(set: [inserted_at: ts])
      end

      stamp.(r_low, 60)
      stamp.(r_high1, 30)
      stamp.(r_high2, 1)

      {:ok, %{ep_high: ep_high, ep_low: ep_low}}
    end

    test "sort_by :usage descending puts the busiest endpoint first", %{ep_high: ep_high} do
      {[first | _], _} = PhoenixKitAI.list_endpoints(sort_by: :usage, sort_dir: :desc)
      assert first.uuid == ep_high.uuid
    end

    test "sort_by :tokens descending matches usage ordering", %{ep_high: ep_high} do
      {[first | _], _} = PhoenixKitAI.list_endpoints(sort_by: :tokens, sort_dir: :desc)
      assert first.uuid == ep_high.uuid
    end

    test "sort_by :cost descending matches usage ordering", %{ep_high: ep_high} do
      {[first | _], _} = PhoenixKitAI.list_endpoints(sort_by: :cost, sort_dir: :desc)
      assert first.uuid == ep_high.uuid
    end

    test "sort_by :last_used descending puts the most recently used first", %{ep_high: ep_high} do
      {[first | _], _} = PhoenixKitAI.list_endpoints(sort_by: :last_used, sort_dir: :desc)
      assert first.uuid == ep_high.uuid
    end

    test "sort_by :name ascending returns alphabetic order" do
      {names, _} = PhoenixKitAI.list_endpoints(sort_by: :name, sort_dir: :asc)
      labels = Enum.map(names, & &1.name)
      assert labels == Enum.sort(labels)
    end

    test "sort_by unknown field falls back to default sort_order ordering" do
      {endpoints, _} = PhoenixKitAI.list_endpoints(sort_by: :unsupported, sort_dir: :asc)
      assert is_list(endpoints)
      assert length(endpoints) >= 2
    end

    test "filter by provider narrows results", %{ep_high: ep_high} do
      {endpoints, total} = PhoenixKitAI.list_endpoints(provider: "openrouter")
      assert total >= 1
      assert ep_high.uuid in Enum.map(endpoints, & &1.uuid)
      refute Enum.any?(endpoints, &(&1.provider != "openrouter"))
    end

    test "filter by enabled=false returns nothing when all are enabled" do
      {endpoints, _} = PhoenixKitAI.list_endpoints(enabled: false)
      assert endpoints == []
    end

    test "page=0 is clamped to page 1" do
      {endpoints, _} = PhoenixKitAI.list_endpoints(page: 0, page_size: 1)
      assert length(endpoints) == 1
    end

    test "preload option threads through" do
      {endpoints, _} = PhoenixKitAI.list_endpoints(preload: [])
      assert is_list(endpoints)
    end
  end

  describe "endpoint stats" do
    test "get_endpoint_usage_stats/0 returns a map keyed by endpoint_uuid" do
      ep = endpoint_fixture()

      _ =
        request_fixture(%{
          endpoint_uuid: ep.uuid,
          total_tokens: 100,
          cost_cents: 25
        })

      stats = PhoenixKitAI.get_endpoint_usage_stats()
      assert is_map(stats[ep.uuid])
      assert stats[ep.uuid].request_count >= 1
      assert stats[ep.uuid].total_tokens >= 100
    end

    test "count_endpoints + count_enabled_endpoints" do
      _ = endpoint_fixture(%{enabled: true})
      _ = endpoint_fixture(%{enabled: false})
      assert PhoenixKitAI.count_endpoints() >= 2
      assert PhoenixKitAI.count_enabled_endpoints() >= 1
    end
  end

  describe "endpoint get + resolve edge cases" do
    test "get_endpoint!/1 raises on missing UUID" do
      assert_raise Ecto.NoResultsError, fn ->
        PhoenixKitAI.get_endpoint!("019abc12-3456-7def-8901-234567890abc")
      end
    end

    test "get_endpoint/1 returns nil for non-textual UUID (16-char slug)" do
      # 16-byte string would be cast as raw UUID by core's helper
      # without our textual_uuid?/1 guard.
      assert PhoenixKitAI.get_endpoint("not-a-real-uuid!") == nil
    end

    test "get_endpoint/1 returns nil for non-binary input" do
      assert PhoenixKitAI.get_endpoint(123) == nil
      assert PhoenixKitAI.get_endpoint(nil) == nil
    end

    test "resolve_endpoint/1 returns :endpoint_not_found for an unknown UUID" do
      uuid = "019abc12-3456-7def-8901-234567890abc"
      assert {:error, :endpoint_not_found} = PhoenixKitAI.resolve_endpoint(uuid)
    end

    test "resolve_endpoint/1 returns :invalid_endpoint_identifier for non-string input" do
      assert {:error, :invalid_endpoint_identifier} = PhoenixKitAI.resolve_endpoint(:atom)
      assert {:error, :invalid_endpoint_identifier} = PhoenixKitAI.resolve_endpoint(nil)
    end

    test "resolve_endpoint/1 returns the struct unchanged" do
      ep = endpoint_fixture()
      assert {:ok, ^ep} = PhoenixKitAI.resolve_endpoint(ep)
    end

    test "change_endpoint/2 returns a changeset" do
      ep = endpoint_fixture()
      changeset = PhoenixKitAI.change_endpoint(ep, %{name: "New"})
      assert %Ecto.Changeset{} = changeset
      assert changeset.changes[:name] == "New"
    end

    test "mark_endpoint_validated/1 stamps last_validated_at" do
      ep = endpoint_fixture()
      assert {:ok, updated} = PhoenixKitAI.mark_endpoint_validated(ep)
      assert updated.last_validated_at != nil
    end

    test "delete_endpoint/2 removes the row + broadcasts :endpoint_deleted" do
      :ok = PhoenixKitAI.subscribe_endpoints()
      ep = endpoint_fixture()
      assert {:ok, _} = PhoenixKitAI.delete_endpoint(ep)
      assert_receive {:endpoint_deleted, %Endpoint{}}, 500
      assert PhoenixKitAI.get_endpoint(ep.uuid) == nil
    end

    test "update_endpoint/3 with enable flip from false→true logs endpoint.enabled" do
      ep = endpoint_fixture(%{enabled: false})
      actor = Ecto.UUID.generate()
      assert {:ok, ep2} = PhoenixKitAI.update_endpoint(ep, %{enabled: true}, actor_uuid: actor)
      assert ep2.enabled == true
      assert_activity_logged("endpoint.enabled", actor_uuid: actor)
    end
  end

  describe "prompt CRUD edge cases + helpers" do
    test "get_prompt!/1 raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        PhoenixKitAI.get_prompt!("019abc12-3456-7def-8901-234567890abc")
      end
    end

    test "get_prompt/1 nil for slug-shaped string + non-binary" do
      assert PhoenixKitAI.get_prompt("not-a-uuid") == nil
      assert PhoenixKitAI.get_prompt(:foo) == nil
    end

    test "get_prompt_by_slug/1 finds by slug" do
      p = prompt_fixture(%{name: "Slug Test"})
      assert ^p = %{PhoenixKitAI.get_prompt_by_slug(p.slug) | __meta__: p.__meta__}
    end

    test "delete_prompt/2 removes + broadcasts" do
      :ok = PhoenixKitAI.subscribe_prompts()
      p = prompt_fixture()
      assert {:ok, _} = PhoenixKitAI.delete_prompt(p)
      assert_receive {:prompt_deleted, %Prompt{}}, 500
    end

    test "update_prompt/3 with enable flip from true→false logs prompt.disabled" do
      p = prompt_fixture(%{enabled: true})
      actor = Ecto.UUID.generate()
      {:ok, _} = PhoenixKitAI.update_prompt(p, %{enabled: false}, actor_uuid: actor)
      assert_activity_logged("prompt.disabled", actor_uuid: actor)
    end

    test "change_prompt/2 returns a changeset" do
      p = prompt_fixture()
      changeset = PhoenixKitAI.change_prompt(p, %{name: "New"})
      assert %Ecto.Changeset{} = changeset
    end

    test "record_prompt_usage/1 increments the counter + stamps last_used_at" do
      p = prompt_fixture()
      assert {:ok, p2} = PhoenixKitAI.record_prompt_usage(p)
      assert p2.usage_count == (p.usage_count || 0) + 1
      assert p2.last_used_at != nil
    end

    test "count_prompts + count_enabled_prompts" do
      _ = prompt_fixture(%{enabled: true})
      _ = prompt_fixture(%{enabled: false})
      assert PhoenixKitAI.count_prompts() >= 2
      assert PhoenixKitAI.count_enabled_prompts() >= 1
    end

    test "list_enabled_prompts/0 excludes disabled" do
      enabled = prompt_fixture(%{enabled: true})
      disabled = prompt_fixture(%{enabled: false})
      uuids = PhoenixKitAI.list_enabled_prompts() |> Enum.map(& &1.uuid)
      assert enabled.uuid in uuids
      refute disabled.uuid in uuids
    end
  end

  describe "resolve_prompt/1" do
    test "returns the struct unchanged" do
      p = prompt_fixture()
      assert {:ok, ^p} = PhoenixKitAI.resolve_prompt(p)
    end

    test "looks up by UUID when input is a 36-char UUID string" do
      p = prompt_fixture()
      assert {:ok, found} = PhoenixKitAI.resolve_prompt(p.uuid)
      assert found.uuid == p.uuid
    end

    test "looks up by slug when input is not a UUID" do
      p = prompt_fixture(%{name: "Slug Lookup"})
      assert {:ok, found} = PhoenixKitAI.resolve_prompt(p.slug)
      assert found.uuid == p.uuid
    end

    test "returns :not_found for missing UUID" do
      uuid = "019abc12-3456-7def-8901-234567890abc"
      assert {:error, {:prompt_error, :not_found}} = PhoenixKitAI.resolve_prompt(uuid)
    end

    test "returns :not_found for missing slug" do
      assert {:error, {:prompt_error, :not_found}} = PhoenixKitAI.resolve_prompt("missing-slug")
    end

    test "returns :invalid_identifier for non-string input" do
      assert {:error, {:prompt_error, :invalid_identifier}} = PhoenixKitAI.resolve_prompt(123)
      assert {:error, {:prompt_error, :invalid_identifier}} = PhoenixKitAI.resolve_prompt(nil)
    end
  end

  describe "render_prompt + increment_prompt_usage + preview_prompt" do
    test "render_prompt/2 substitutes variables" do
      p = prompt_fixture(%{content: "Hi {{Name}}"})
      assert {:ok, "Hi World"} = PhoenixKitAI.render_prompt(p.uuid, %{"Name" => "World"})
    end

    test "render_prompt/2 returns :not_found for missing uuid" do
      uuid = "019abc12-3456-7def-8901-234567890abc"
      assert {:error, {:prompt_error, :not_found}} = PhoenixKitAI.render_prompt(uuid)
    end

    test "increment_prompt_usage/1 raises usage_count" do
      p = prompt_fixture()
      assert {:ok, p2} = PhoenixKitAI.increment_prompt_usage(p.uuid)
      assert p2.usage_count == 1
    end

    test "preview_prompt/2 mirrors render_prompt" do
      p = prompt_fixture(%{content: "Hello {{Who}}"})
      assert {:ok, "Hello PR"} = PhoenixKitAI.preview_prompt(p.uuid, %{"Who" => "PR"})
    end

    test "get_prompt_variables/1 returns variable list" do
      p = prompt_fixture(%{content: "{{A}} and {{B}}"})
      assert {:ok, vars} = PhoenixKitAI.get_prompt_variables(p.uuid)
      assert Enum.sort(vars) == ["A", "B"]
    end

    test "validate_prompt_variables/2 returns :ok when complete" do
      p = prompt_fixture(%{content: "{{A}}"})
      assert :ok = PhoenixKitAI.validate_prompt_variables(p.uuid, %{"A" => "x"})
    end

    test "validate_prompt_variables/2 returns missing list" do
      p = prompt_fixture(%{content: "{{A}} {{B}}"})
      assert {:error, ["B"]} = PhoenixKitAI.validate_prompt_variables(p.uuid, %{"A" => "x"})
    end
  end

  describe "validate_prompt + duplicate + enable/disable" do
    test "validate_prompt/1 fails on empty content" do
      p = %Prompt{content: "", enabled: true}
      assert {:error, {:prompt_error, :empty_content}} = PhoenixKitAI.validate_prompt(p)
    end

    test "validate_prompt/1 fails on nil content" do
      p = %Prompt{content: nil, enabled: true}
      assert {:error, {:prompt_error, :empty_content}} = PhoenixKitAI.validate_prompt(p)
    end

    test "validate_prompt/1 fails when disabled" do
      p = %Prompt{content: "x", enabled: false}
      assert {:error, {:prompt_error, :disabled}} = PhoenixKitAI.validate_prompt(p)
    end

    test "validate_prompt/1 succeeds for enabled non-empty" do
      p = %Prompt{content: "x", enabled: true}
      assert {:ok, ^p} = PhoenixKitAI.validate_prompt(p)
    end

    test "duplicate_prompt/2 copies the source prompt with the new name" do
      p = prompt_fixture(%{content: "{{X}}", description: "src"})
      assert {:ok, copy} = PhoenixKitAI.duplicate_prompt(p.uuid, "Copy-#{p.uuid}")
      assert copy.uuid != p.uuid
      assert copy.content == p.content
      assert copy.description == p.description
    end

    test "duplicate_prompt/2 returns :not_found for unknown uuid" do
      uuid = "019abc12-3456-7def-8901-234567890abc"
      assert {:error, {:prompt_error, :not_found}} = PhoenixKitAI.duplicate_prompt(uuid, "X")
    end

    test "enable_prompt/1 + disable_prompt/1 flip the flag" do
      p = prompt_fixture(%{enabled: false})
      assert {:ok, p2} = PhoenixKitAI.enable_prompt(p.uuid)
      assert p2.enabled == true
      assert {:ok, p3} = PhoenixKitAI.disable_prompt(p.uuid)
      assert p3.enabled == false
    end
  end

  describe "search_prompts + get_prompts_with_variable + validate_prompt_content" do
    test "search_prompts/2 matches by name (ilike)" do
      a = prompt_fixture(%{name: "Translator AB"})
      _b = prompt_fixture(%{name: "Other"})
      results = PhoenixKitAI.search_prompts("translator")
      uuids = Enum.map(results, & &1.uuid)
      assert a.uuid in uuids
    end

    test "search_prompts/2 honours :enabled filter" do
      a = prompt_fixture(%{name: "Search Enabled", enabled: true})
      b = prompt_fixture(%{name: "Search Disabled", enabled: false})
      results = PhoenixKitAI.search_prompts("search", enabled: true)
      uuids = Enum.map(results, & &1.uuid)
      assert a.uuid in uuids
      refute b.uuid in uuids
    end

    test "get_prompts_with_variable/1 returns prompts using that variable" do
      p = prompt_fixture(%{content: "Welcome {{User}}"})
      results = PhoenixKitAI.get_prompts_with_variable("User")
      assert p.uuid in Enum.map(results, & &1.uuid)
    end

    test "validate_prompt_content/1 :ok when all variables look valid" do
      assert :ok = PhoenixKitAI.validate_prompt_content("Hello {{Name}}")
    end

    test "validate_prompt_content/1 lists invalid variable names" do
      # `validate_prompt_content` allows `\w+` (so `1bad` is fine);
      # invalid means anything outside that — e.g. spaces or hyphens.
      assert {:error, invalid} = PhoenixKitAI.validate_prompt_content("Hi {{bad name}}")
      assert "bad name" in invalid
    end

    test "validate_prompt_content/1 returns :content_not_string on non-binary input" do
      assert {:error, {:prompt_error, :content_not_string}} =
               PhoenixKitAI.validate_prompt_content(123)
    end
  end

  describe "prompt usage stats + reset + reorder" do
    test "get_prompt_usage_stats/1 honours :limit + :enabled" do
      p1 = prompt_fixture(%{name: "PStat A", enabled: true})
      p2 = prompt_fixture(%{name: "PStat B", enabled: false})
      stats = PhoenixKitAI.get_prompt_usage_stats(enabled: true, limit: 100)
      uuids = Enum.map(stats, & &1.prompt.uuid)
      assert p1.uuid in uuids
      refute p2.uuid in uuids
    end

    test "get_prompt_usage_stats/0 returns all prompts when no filter is given" do
      _p = prompt_fixture()
      assert is_list(PhoenixKitAI.get_prompt_usage_stats())
    end

    test "reset_prompt_usage/1 zeroes the counter" do
      p = prompt_fixture()
      {:ok, _} = PhoenixKitAI.record_prompt_usage(p)
      assert {:ok, p2} = PhoenixKitAI.reset_prompt_usage(p.uuid)
      assert p2.usage_count == 0
      assert p2.last_used_at == nil
    end

    test "reset_prompt_usage/1 returns error for missing uuid" do
      uuid = "019abc12-3456-7def-8901-234567890abc"
      assert {:error, {:prompt_error, :not_found}} = PhoenixKitAI.reset_prompt_usage(uuid)
    end

    test "reorder_prompts/1 updates sort_order via UUID" do
      p1 = prompt_fixture(%{sort_order: 0})
      p2 = prompt_fixture(%{sort_order: 1})

      assert :ok = PhoenixKitAI.reorder_prompts([{p1.uuid, 99}, {p2.uuid, 100}])

      assert PhoenixKitAI.get_prompt(p1.uuid).sort_order == 99
      assert PhoenixKitAI.get_prompt(p2.uuid).sort_order == 100
    end

    test "reorder_prompts/1 silently no-ops on a non-UUID id" do
      p = prompt_fixture(%{sort_order: 5})
      assert :ok = PhoenixKitAI.reorder_prompts([{"not-a-uuid", 99}, {p.uuid, 7}])
      assert PhoenixKitAI.get_prompt(p.uuid).sort_order == 7
    end
  end

  describe "request listing + filtering + sorting" do
    setup do
      ep1 = endpoint_fixture(%{name: "Req EP1"})
      ep2 = endpoint_fixture(%{name: "Req EP2"})

      r1 =
        request_fixture(%{
          endpoint_uuid: ep1.uuid,
          endpoint_name: ep1.name,
          model: "model-A",
          status: "success",
          total_tokens: 100,
          cost_cents: 50,
          metadata: %{"source" => "MyApp"}
        })

      r2 =
        request_fixture(%{
          endpoint_uuid: ep2.uuid,
          endpoint_name: ep2.name,
          model: "model-B",
          status: "error",
          total_tokens: 0,
          metadata: %{"source" => "OtherApp"}
        })

      {:ok, %{ep1: ep1, ep2: ep2, r1: r1, r2: r2}}
    end

    test "list_requests/1 paginates and counts" do
      {requests, total} = PhoenixKitAI.list_requests(page: 1, page_size: 1)
      assert length(requests) == 1
      assert total >= 2
    end

    test "filter by :endpoint_uuid", %{ep1: ep1, r1: r1} do
      {requests, total} = PhoenixKitAI.list_requests(endpoint_uuid: ep1.uuid)
      assert total >= 1
      assert r1.uuid in Enum.map(requests, & &1.uuid)
    end

    test "filter by :status", %{r1: r1} do
      {requests, _} = PhoenixKitAI.list_requests(status: "success")
      assert r1.uuid in Enum.map(requests, & &1.uuid)
    end

    test "filter by :model", %{r1: r1} do
      {requests, _} = PhoenixKitAI.list_requests(model: "model-A")
      assert r1.uuid in Enum.map(requests, & &1.uuid)
    end

    test "filter by :source (metadata JSONB)", %{r1: r1} do
      {requests, _} = PhoenixKitAI.list_requests(source: "MyApp")
      assert r1.uuid in Enum.map(requests, & &1.uuid)
    end

    test "filter by :user_uuid restricts to that user" do
      ep = endpoint_fixture()
      user_uuid = Ecto.UUID.generate()

      r =
        request_fixture(%{
          endpoint_uuid: ep.uuid,
          user_uuid: user_uuid,
          status: "success"
        })

      {requests, _} = PhoenixKitAI.list_requests(user_uuid: user_uuid)
      assert r.uuid in Enum.map(requests, & &1.uuid)
    end

    test "filter by :since (DateTime)" do
      ep = endpoint_fixture()
      _ = request_fixture(%{endpoint_uuid: ep.uuid})
      one_day_ahead = DateTime.utc_now() |> DateTime.add(86_400, :second)
      {requests, _} = PhoenixKitAI.list_requests(since: one_day_ahead)
      assert requests == []
    end

    test "sort_by every supported field" do
      for field <- [
            :inserted_at,
            :model,
            :total_tokens,
            :latency_ms,
            :cost_cents,
            :status,
            :endpoint_name
          ] do
        {requests, _} = PhoenixKitAI.list_requests(sort_by: field, sort_dir: :asc)
        assert is_list(requests)
      end
    end

    test "sort_by unsupported field falls back to inserted_at" do
      {requests, _} = PhoenixKitAI.list_requests(sort_by: :nonsense)
      assert is_list(requests)
    end

    test "preload threads through" do
      {requests, _} = PhoenixKitAI.list_requests(preload: [])
      assert is_list(requests)
    end

    test "get_request!/1 raises on missing uuid" do
      assert_raise Ecto.NoResultsError, fn ->
        PhoenixKitAI.get_request!("019abc12-3456-7def-8901-234567890abc")
      end
    end

    test "get_request/1 returns the request when present", %{r1: r1} do
      assert PhoenixKitAI.get_request(r1.uuid).uuid == r1.uuid
    end

    test "get_request/1 returns nil for non-textual UUID + non-binary" do
      assert PhoenixKitAI.get_request("nope") == nil
      assert PhoenixKitAI.get_request(:foo) == nil
    end

    test "count_requests + sum_tokens reflect inserted rows" do
      assert PhoenixKitAI.count_requests() >= 2
      assert PhoenixKitAI.sum_tokens() >= 100
    end

    test "get_request_filter_options/0 returns endpoint, model, status, source lists" do
      opts = PhoenixKitAI.get_request_filter_options()
      assert is_list(opts.endpoints)
      assert is_list(opts.models)
      assert "success" in opts.statuses
      assert is_list(opts.sources)
    end
  end

  describe "stats — usage / dashboard / tokens / requests-by-day" do
    setup do
      ep = endpoint_fixture()

      _ =
        request_fixture(%{
          endpoint_uuid: ep.uuid,
          model: "stats-model",
          status: "success",
          total_tokens: 50,
          latency_ms: 200,
          cost_cents: 10
        })

      _ =
        request_fixture(%{
          endpoint_uuid: ep.uuid,
          model: "stats-model",
          status: "error",
          total_tokens: 0
        })

      :ok
    end

    test "get_usage_stats/0 returns aggregate map with success_rate" do
      stats = PhoenixKitAI.get_usage_stats()
      assert stats.total_requests >= 2
      assert stats.total_tokens >= 50
      assert is_float(stats.success_rate)
      assert is_integer(stats.avg_latency_ms) or stats.avg_latency_ms == nil
    end

    test "get_usage_stats/0 returns success_rate=0.0 when no requests match the filter" do
      ep = endpoint_fixture()
      stats = PhoenixKitAI.get_usage_stats(endpoint_uuid: ep.uuid)
      assert stats.total_requests == 0
      assert stats.success_rate == 0.0
    end

    test "get_dashboard_stats/0 returns the multi-window map" do
      stats = PhoenixKitAI.get_dashboard_stats()
      assert is_map(stats.all_time)
      assert is_map(stats.last_30_days)
      assert is_map(stats.today)
      assert is_list(stats.tokens_by_model)
      assert is_list(stats.requests_by_day)
    end

    test "get_tokens_by_model/0 groups by model" do
      result = PhoenixKitAI.get_tokens_by_model()
      assert Enum.any?(result, &(&1.model == "stats-model"))
    end

    test "get_requests_by_day/0 returns date+count buckets" do
      result = PhoenixKitAI.get_requests_by_day()
      assert is_list(result)
      assert Enum.all?(result, &Map.has_key?(&1, :count))
    end
  end
end
