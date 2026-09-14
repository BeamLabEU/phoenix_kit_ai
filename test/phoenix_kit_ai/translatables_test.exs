defmodule PhoenixKitAI.TranslatablesTest do
  @moduledoc "Host apps joining the translation pipeline from config."

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitAI.Translatables

  defmodule FakeProductTranslatable do
    @moduledoc false
    def fetch(_uuid, _opts), do: {:error, :not_found}
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :translatables) end)
    :ok
  end

  test "a host's {type, module} pairs join discovery and come first" do
    Application.put_env(:phoenix_kit_ai, :translatables, [{"product", FakeProductTranslatable}])

    assert Translatables.all()["product"] == FakeProductTranslatable
    assert Translatables.find("product") == FakeProductTranslatable
    assert Translatables.find("nope") == nil
  end

  test "malformed entries are skipped with a warning; a non-list config is ignored" do
    Application.put_env(:phoenix_kit_ai, :translatables, [
      {"product", FakeProductTranslatable},
      {"bad", "no"},
      :junk
    ])

    log = capture_log(fn -> refute Map.has_key?(Translatables.all(), "bad") end)
    assert log =~ ~s(ignoring :translatables entry {"bad", "no"})
    assert log =~ "ignoring :translatables entry :junk"

    Application.put_env(:phoenix_kit_ai, :translatables, "nope")
    log = capture_log(fn -> refute Map.has_key?(Translatables.all(), "product") end)
    assert log =~ ":translatables must be a list"
  end

  test "a module that is not loaded or has no fetch/2 is kept but warned about" do
    Application.put_env(:phoenix_kit_ai, :translatables, [{"ghost", Missing.Adapter}])

    log = capture_log(fn -> assert Translatables.find("ghost") == Missing.Adapter end)
    assert log =~ "Missing.Adapter is not loaded or has no fetch/2"
  end
end
