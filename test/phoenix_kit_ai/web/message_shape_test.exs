defmodule PhoenixKitAI.Web.MessageShapeTest do
  use ExUnit.Case, async: true

  alias PhoenixKitAI.Web.MessageShape

  doctest MessageShape

  describe "describe_exit/1" do
    test "names a crash by its exception and place, never its message or arguments" do
      stack = [{PhoenixKitAI, :transcribe, 3, [file: ~c"lib/phoenix_kit_ai.ex", line: 42]}]

      assert MessageShape.describe_exit({%ArgumentError{message: "the words"}, stack}) ==
               "ArgumentError in PhoenixKitAI.transcribe/3 (lib/phoenix_kit_ai.ex:42)"
    end

    test "a raw exit with a stacktrace is described by its reason" do
      stack = [{GenServer, :call, [:secret], []}]
      assert MessageShape.describe_exit({{:badmatch, "secret"}, stack}) == "{:badmatch, …}/2"
    end

    test "anything else is its shape" do
      assert MessageShape.describe_exit(:killed) == ":killed"
      assert MessageShape.describe_exit("secret") == "binary"
    end
  end
end
