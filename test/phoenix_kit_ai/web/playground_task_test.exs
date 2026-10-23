defmodule PhoenixKitAI.Web.PlaygroundTaskTest do
  @moduledoc """
  Playground calls are the `ai.playground` task, made by the signed-in
  user: the usage rows carry the user and the task (chat and describe).
  The provider is a `Req.Test` stub.
  """

  use PhoenixKitAI.LiveCase

  import Ecto.Query

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitAI.Request
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "model" => "m",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi back!"}}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      })
    end)

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    user_uuid = Fixtures.confirmed_user_fixture().uuid
    conn = put_test_scope(build_conn(), fake_scope(user_uuid: user_uuid))
    {:ok, conn: conn, user_uuid: user_uuid}
  end

  defp rows(endpoint),
    do: TestRepo.all(from(r in Request, where: r.endpoint_uuid == ^endpoint.uuid))

  test "a freeform send is billed to the user under ai.playground", %{
    conn: conn,
    user_uuid: user_uuid
  } do
    ep = fixture_endpoint()
    {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

    render_change(view, "change", %{"message" => "Hello"})
    render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
    render_hook(view, "send", %{})
    assert render(view) =~ "Hi back!"

    assert [%Request{user_uuid: ^user_uuid, metadata: %{"task" => "ai.playground"}}] = rows(ep)
  end

  test "a prompt send carries them too", %{conn: conn, user_uuid: user_uuid} do
    ep = fixture_endpoint()
    prompt = fixture_prompt(content: "Say hi to {{Name}}")
    {:ok, view, _html} = live(conn, "/en/admin/ai/playground")

    render_change(view, "change", %{"endpoint_uuid" => ep.uuid})
    render_change(view, "change", %{"prompt_uuid" => prompt.uuid})
    render_change(view, "change", %{"variables" => %{"Name" => "Ann"}})
    render_hook(view, "send", %{})
    assert render(view) =~ "Hi back!"

    assert [%Request{user_uuid: ^user_uuid, metadata: %{"task" => "ai.playground"}}] = rows(ep)
  end
end
