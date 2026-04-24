defmodule PhoenixKitAI.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring access to the
  application's data layer.

  Tests using this case are **automatically tagged `:integration`** so
  they are excluded when the test database is unavailable (the tag is
  filtered out in `test/test_helper.exs`).

  The SQL sandbox is enabled so changes done to the database are
  reverted at the end of every test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitAI.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitAI.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAI.Test

  setup tags do
    pid = Sandbox.start_owner!(Test.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
