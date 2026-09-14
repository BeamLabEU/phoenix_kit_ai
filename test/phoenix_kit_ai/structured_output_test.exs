defmodule PhoenixKitAI.StructuredOutputTest do
  @moduledoc "JSON answers on ask/3 and complete/3."

  use PhoenixKitAI.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitAI.{Request, StructuredOutput}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.StructuredOutputTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "JSON-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    {:ok, endpoint: ep}
  end

  defp stub(answers) when is_function(answers, 1) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:post, body})

      case answers.(body) do
        {status, payload} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(payload))
      end
    end)
  end

  defp chat(content),
    do: %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
    }

  describe "StructuredOutput" do
    test "attach appends to the last user message, string or parts, either key style" do
      assert [%{role: "system", content: "s"}, %{role: "user", content: "hi\n\nJSON please"}] =
               StructuredOutput.attach(
                 [%{role: "system", content: "s"}, %{role: "user", content: "hi"}],
                 "JSON please"
               )

      assert [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "text", "text" => "a"},
                   %{"type" => "text", "text" => "X"}
                 ]
               }
             ] =
               StructuredOutput.attach(
                 [%{"role" => "user", "content" => [%{"type" => "text", "text" => "a"}]}],
                 "X"
               )

      assert [%{role: "system", content: "s"}, %{role: "user", content: "X"}] =
               StructuredOutput.attach([%{role: "system", content: "s"}], "X")
    end

    test "parse tolerates fences and refuses non-objects" do
      assert {:ok, %{"a" => 1}} = StructuredOutput.parse(~s(```json\n{"a": 1}\n```), true)
      assert {:ok, [1, 2]} = StructuredOutput.parse("[1,2]", true)
      assert {:error, {:no_json_in_response, "42"}} = StructuredOutput.parse("42", true)

      # Prose around a fence, and prose around bare braces, both parse.
      assert {:ok, %{"a" => 1}} =
               StructuredOutput.parse(
                 "Here you go:\n```json\n{\"a\": 1}\n```\nHope it helps",
                 true
               )

      assert {:ok, %{"a" => 1}} = StructuredOutput.parse("Sure — {\"a\": 1} — done.", true)
      assert {:ok, nil} = StructuredOutput.parse("anything", false)
    end
  end

  describe "ask/3 and complete/3 with schema: / json:" do
    test "requests json_schema, puts the schema in the prompt and returns the parsed object", %{
      endpoint: ep
    } do
      stub(fn _ -> {200, chat(~s({"axes": ["crunch", "sweetness"]}))} end)
      schema = %{"type" => "object", "properties" => %{"axes" => %{"type" => "array"}}}

      assert {:ok, %{"json" => %{"axes" => ["crunch", "sweetness"]}}} =
               PhoenixKitAI.ask(ep.uuid, "Propose rating axes for chocolate bars.",
                 schema: schema,
                 system: "Be terse."
               )

      assert_received {:post, body}

      assert %{"type" => "json_schema", "json_schema" => %{"schema" => ^schema, "strict" => true}} =
               body["response_format"]

      assert [
               %{"role" => "system", "content" => "Be terse."},
               %{"role" => "user", "content" => user}
             ] = body["messages"]

      assert user =~ "Propose rating axes"
      assert user =~ "matching this JSON Schema"
      assert user =~ ~s("axes")
    end

    test "json: true uses json_object; a model that rejects response_format gets one retry without it",
         %{endpoint: ep} do
      stub(fn body ->
        if Map.has_key?(body, "response_format"),
          do: {400, %{"error" => %{"message" => "response_format unsupported"}}},
          else: {200, chat(~s({"ok": true}))}
      end)

      assert {:ok, %{"json" => %{"ok" => true}}} =
               PhoenixKitAI.complete(ep.uuid, [%{role: "user", content: "yes?"}], json: true)

      assert_received {:post, %{"response_format" => %{"type" => "json_object"}}}
      assert_received {:post, second}
      refute Map.has_key?(second, "response_format")
    end

    test "422 also retries once; a 500 does not; the caller's own response_format passes through",
         %{endpoint: ep} do
      stub(fn body ->
        if Map.has_key?(body, "response_format"),
          do: {422, %{"error" => %{"message" => "no"}}},
          else: {200, chat(~s({"ok": true}))}
      end)

      assert {:ok, %{"json" => %{"ok" => true}}} = PhoenixKitAI.ask(ep.uuid, "x", json: true)
      assert_received {:post, %{"response_format" => _}}
      assert_received {:post, _second}

      stub(fn _ -> {500, %{"error" => %{"message" => "boom"}}} end)
      assert {:error, _} = PhoenixKitAI.ask(ep.uuid, "x", json: true)
      assert_received {:post, _only}
      refute_received {:post, _}

      stub(fn _ -> {200, chat("plain")} end)
      custom = %{"type" => "json_object"}
      assert {:ok, response} = PhoenixKitAI.ask(ep.uuid, "x", response_format: custom)
      refute Map.has_key?(response, "json")
      assert_received {:post, %{"response_format" => ^custom}}
    end

    test "a prose answer to a JSON request is logged but never cached", %{endpoint: ep} do
      stub(fn _ -> {200, chat("Sure! Here you go.")} end)

      assert {:error, {:no_json_in_response, _}} =
               PhoenixKitAI.ask(ep.uuid, "again", json: true, cache: true)

      assert_received {:post, _}

      stub(fn _ -> {200, chat(~s({"ok": 1}))} end)

      assert {:ok, %{"json" => %{"ok" => 1}}} =
               PhoenixKitAI.ask(ep.uuid, "again", json: true, cache: true)

      assert_received {:post, _}

      # One success row per provider call, none for the parse failure itself.
      assert 2 =
               TestRepo.aggregate(from(r in Request, where: r.endpoint_uuid == ^ep.uuid), :count)
    end

    test "prose where JSON was asked for is an error; without schema/json nothing changes", %{
      endpoint: ep
    } do
      stub(fn _ -> {200, chat("Sure! Here you go.")} end)

      assert {:error, {:no_json_in_response, "Sure! Here you go."}} =
               PhoenixKitAI.ask(ep.uuid, "x", json: true)

      assert {:ok, response} = PhoenixKitAI.ask(ep.uuid, "x")
      refute Map.has_key?(response, "json")
      assert_received {:post, %{"messages" => [%{"content" => "x"}]} = plain}
      refute Map.has_key?(plain, "response_format")
    end
  end
end
