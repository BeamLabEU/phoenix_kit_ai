defmodule PhoenixKitAI.PromptChangesetTest do
  # async: false — the activity log attempt hits a shared connection
  # without a `phoenix_kit_activities` table in our test DB; running
  # parallel tests can transiently poison the sandbox before the
  # resolve_prompt assertion.
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Prompt

  describe "changeset/2 — validation" do
    test "requires name and content" do
      changeset = Prompt.changeset(%Prompt{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:name]
      assert errors[:content]
    end

    test "accepts a minimal valid prompt" do
      changeset = Prompt.changeset(%Prompt{}, %{name: "Greeter", content: "Hello!"})
      assert changeset.valid?
    end

    test "rejects name longer than 100 chars" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: String.duplicate("x", 101),
          content: "Hi"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:name]
    end

    test "rejects description longer than 500 chars" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Short",
          content: "Hi",
          description: String.duplicate("x", 501)
        })

      refute changeset.valid?
      assert errors_on(changeset)[:description]
    end

    test "auto-extracts variable names from content" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Extractor",
          content: "Hi {{Name}}, welcome to {{Place}}."
        })

      assert Ecto.Changeset.get_field(changeset, :variables) == ["Name", "Place"]
    end

    test "auto-generates a slug from the name when absent" do
      changeset = Prompt.changeset(%Prompt{}, %{name: "My Great Prompt", content: "Hi"})
      slug = Ecto.Changeset.get_field(changeset, :slug)
      assert slug == "my-great-prompt"
    end
  end

  describe "create_prompt/2 (integration)" do
    test "persists a prompt with auto-extracted variables and slug" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Translator #{System.unique_integer([:positive])}",
          content: "Translate {{Text}} to {{Language}}."
        })

      assert prompt.uuid
      assert prompt.variables == ["Text", "Language"]
      assert is_binary(prompt.slug)
    end

    test "rejects duplicate names" do
      name = "Dup Prompt #{System.unique_integer([:positive])}"
      {:ok, _first} = PhoenixKitAI.create_prompt(%{name: name, content: "Hi"})
      {:error, changeset} = PhoenixKitAI.create_prompt(%{name: name, content: "Hi again"})

      assert errors_on(changeset)[:name]
    end

    test "duplicate slugs are prevented at the DB level" do
      # The changeset rewrites slug from name on every change, so the
      # only practical way to hit the slug unique constraint is two
      # names that slugify to the same string. We verify the guard is
      # declared — the DB index and unique_constraint match up.
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Slug Owner #{System.unique_integer([:positive])}",
          content: "Hi"
        })

      assert Enum.any?(changeset.constraints, fn c ->
               c.field == :slug and c.constraint == "phoenix_kit_ai_prompts_slug_uidx"
             end)
    end
  end

  describe "update_prompt/3 and delete_prompt/2" do
    test "update modifies the row" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Update #{System.unique_integer([:positive])}",
          content: "Original"
        })

      {:ok, updated} = PhoenixKitAI.update_prompt(prompt, %{content: "New content"})
      assert updated.content == "New content"
    end

    test "delete removes the row" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Delete #{System.unique_integer([:positive])}",
          content: "Bye"
        })

      {:ok, _} = PhoenixKitAI.delete_prompt(prompt)
      assert PhoenixKitAI.get_prompt(prompt.uuid) == nil
    end
  end

  describe "resolve_prompt/1" do
    test "finds a prompt by UUID" do
      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: "Resolve UUID #{System.unique_integer([:positive])}",
          content: "Hi"
        })

      assert {:ok, ^prompt} = PhoenixKitAI.resolve_prompt(prompt.uuid)
    end

    test "finds a prompt by slug" do
      # Use a name that slugifies to something clearly longer than 16
      # characters so the UUID-vs-slug dispatch in `resolve_prompt`
      # never mis-classifies it. (Any 16-byte string passes
      # `Ecto.UUID.cast/1` as a raw UUID — the context module's
      # `textual_uuid?/1` guards against that by also checking
      # `byte_size == 36`, but we keep the slug comfortably outside
      # that trap range here regardless.)
      name = "Resolve Prompt Slug Lookup #{System.unique_integer([:positive])}"

      {:ok, prompt} =
        PhoenixKitAI.create_prompt(%{
          name: name,
          content: "Hi"
        })

      slug = prompt.slug
      assert is_binary(slug)

      assert {:ok, found} = PhoenixKitAI.resolve_prompt(slug)
      assert found.uuid == prompt.uuid
    end

    test "resolve_prompt treats a 16-char slug as a slug (regression)" do
      # A 16-byte slug would otherwise be mis-cast as a UUID by
      # Ecto.UUID.cast/1. The fixture name is picked so slugify yields
      # exactly 16 chars; if UUID dispatch leaks through, this fails.
      name = "sixteen chars aa"
      {:ok, prompt} = PhoenixKitAI.create_prompt(%{name: name, content: "Hi"})

      # Sanity on the fixture: slugify must return exactly 16 bytes for
      # this test to hit the regression case. Assert up front so a
      # slugify rule change flags itself instead of silently dropping
      # coverage.
      assert byte_size(prompt.slug) == 16,
             "expected 16-byte slug to exercise the UUID-vs-slug dispatch; got #{inspect(prompt.slug)}"

      assert {:ok, found} = PhoenixKitAI.resolve_prompt(prompt.slug)
      assert found.uuid == prompt.uuid
    end

    test "returns :not_found for missing UUID" do
      assert {:error, {:prompt_error, :not_found}} =
               PhoenixKitAI.resolve_prompt("01234567-89ab-7def-8000-000000000000")
    end

    test "returns :not_found for missing slug" do
      assert {:error, {:prompt_error, :not_found}} =
               PhoenixKitAI.resolve_prompt("non-existent-slug-xyz")
    end

    test "returns :invalid_identifier for nonsense input" do
      assert {:error, {:prompt_error, :invalid_identifier}} = PhoenixKitAI.resolve_prompt(123)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
