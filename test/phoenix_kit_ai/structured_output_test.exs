defmodule PhoenixKitAI.StructuredOutputTest do
  @moduledoc "JSON answers on ask/3 and complete/3, and the host translatables seam."

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{StructuredOutput, Translatables}

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
      Application.delete_env(:phoenix_kit_ai, :translatables)
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
      assert {:error, {:no_json_in_response, "[1,2]"}} = StructuredOutput.parse("[1,2]", true)
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

  describe "Translatables from config" do
    test "a host's {type, module} pairs join discovery and come first" do
      Application.put_env(:phoenix_kit_ai, :translatables, [
        {"product", Ratelia.Fake.ProductTranslatable},
        {"bad", "no"},
        :junk
      ])

      all = Translatables.all()
      assert all["product"] == Ratelia.Fake.ProductTranslatable
      assert Translatables.find("product") == Ratelia.Fake.ProductTranslatable
      refute Map.has_key?(all, "bad")
    end
  end
end
