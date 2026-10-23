defmodule PhoenixKitAI.Test.FakeUsageSink do
  @moduledoc """
  A usage sink (`handle_ai_usage/1`) that forwards every row it receives to
  the pid in the `:fake_usage_sink_pid` app env.
  """

  def handle_ai_usage(request) do
    case Application.get_env(:phoenix_kit_ai, :fake_usage_sink_pid) do
      pid when is_pid(pid) -> send(pid, {:usage_sink, request})
      _ -> :ok
    end
  end
end
