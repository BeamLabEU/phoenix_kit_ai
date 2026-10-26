defmodule PhoenixKitAI.Web.JournalRetentionTest do
  @moduledoc """
  The retention card's preview results, without a page: a result is taken
  only by the preview pending under the same reference, a task that exited
  is a failure (not a timeout), and only a timeout leaves the run possible
  without numbers.
  """

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias PhoenixKitAI.Errors
  alias PhoenixKitAI.Web.Components.JournalRetentionCard
  alias PhoenixKitAI.Web.JournalRetention

  @counts %{content: 0, requests: 2, guard_events: 0, clamped: [], cutoffs: %{}}

  defp socket(pending) do
    %Socket{}
    |> Phoenix.Component.assign(:retention_run, pending)
    |> Phoenix.Component.assign(:retention_save, nil)
  end

  defp pending(ref), do: %{ref: ref, cutoffs: %{}, preview: :loading, confirm: false}

  defp preview_of({:noreply, socket}),
    do: socket.assigns.retention_run && socket.assigns.retention_run.preview

  test "the pending preview takes its own result" do
    ref = make_ref()

    result =
      JournalRetention.handle_async(
        :retention_run_preview,
        {:ok, {ref, {:ok, @counts}}},
        socket(pending(ref))
      )

    assert preview_of(result) == {:ok, @counts}
  end

  test "a result under another reference is dropped" do
    result =
      JournalRetention.handle_async(
        :retention_run_preview,
        {:ok, {make_ref(), {:ok, @counts}}},
        socket(pending(make_ref()))
      )

    assert preview_of(result) == :loading
  end

  test "a result with nothing pending is dropped" do
    result =
      JournalRetention.handle_async(
        :retention_run_preview,
        {:ok, {make_ref(), {:ok, @counts}}},
        socket(nil)
      )

    assert preview_of(result) == nil
  end

  test "a task that exited is a failed preview, which does not allow the run" do
    ref = make_ref()

    result =
      JournalRetention.handle_async(:retention_run_preview, {:exit, :boom}, socket(pending(ref)))

    assert preview_of(result) == {:error, :preview_failed}
    refute JournalRetention.runnable?(%{preview: {:error, :preview_failed}})
    assert JournalRetention.runnable?(%{preview: {:error, :preview_timeout}})

    assert JournalRetentionCard.preview_messages({:error, :preview_failed}, [:requests]) ==
             [{:error, Errors.message(:preview_failed)}]
  end
end
