defmodule PhoenixKitAI.ContentHashesTest do
  @moduledoc "\"Has this content changed since last time?\" — `PhoenixKitAI.ContentHashes`."

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{ContentHash, ContentHashes}

  @ns "test:pages"

  describe "hash/2" do
    test "ignores re-indentation, line endings and Unicode composition" do
      a = ContentHashes.hash("Hello   world\r\n\tsecond line ")
      b = ContentHashes.hash("Hello world\nsecond line")
      assert a == b
      assert "sha256:" <> hex = a
      assert byte_size(hex) == 64

      # "é" composed and decomposed
      assert ContentHashes.hash("café") == ContentHashes.hash("café")
      refute ContentHashes.hash("Hello world") == ContentHashes.hash("Hello World")
    end

    test "normalize: false hashes the bytes as given" do
      refute ContentHashes.hash("a  b", normalize: false) ==
               ContentHashes.hash("a b", normalize: false)
    end

    test "a map of fields is hashed in key order, whatever order it lists them in" do
      one = ContentHashes.hash(%{"title" => "T", "body" => "B"})
      two = ContentHashes.hash(Map.new([{"body", "B"}, {"title", "T"}]))
      assert one == two
      assert ContentHashes.hash(%{title: "T", body: "B"}) == one
      refute ContentHashes.hash(%{"title" => "B", "body" => "T"}) == one
      # A field's name is part of the material, not just the texts.
      refute ContentHashes.hash(%{"a" => "x"}) == ContentHashes.hash(%{"b" => "x"})
    end

    test "{:hash, hash} passes a hash the caller already holds" do
      assert ContentHashes.hash({:hash, "sha256:abc"}) == "sha256:abc"
    end
  end

  describe "check/3, record/4" do
    test "new, then unchanged, then changed; check only reads" do
      assert {:new, hash} = ContentHashes.check(@ns, "https://a.test/1", "text one")
      assert {:new, ^hash} = ContentHashes.check(@ns, "https://a.test/1", "text one")
      assert ContentHashes.changed?(@ns, "https://a.test/1", "text one")

      t0 = ~U[2026-11-20 10:00:00.000000Z]
      assert {:ok, :new, row} = ContentHashes.record(@ns, "https://a.test/1", "text one", now: t0)
      assert %ContentHash{content_hash: ^hash, content_bytes: 8, changed_at: ^t0} = row

      assert {:unchanged, ^hash} = ContentHashes.check(@ns, "https://a.test/1", " text  one ")
      refute ContentHashes.changed?(@ns, "https://a.test/1", "text one")

      # Recording the same content moves checked_at, never changed_at.
      t1 = ~U[2026-11-21 10:00:00.000000Z]

      assert {:ok, :unchanged, row} =
               ContentHashes.record(@ns, "https://a.test/1", {:hash, hash}, now: t1)

      assert row.changed_at == t0
      assert row.checked_at == t1

      assert {:changed, other} = ContentHashes.check(@ns, "https://a.test/1", "text two")
      t2 = ~U[2026-11-22 10:00:00.000000Z]

      assert {:ok, :changed, row} =
               ContentHashes.record(@ns, "https://a.test/1", "text two",
                 now: t2,
                 metadata: %{"page_id" => 5}
               )

      assert row.content_hash == other
      assert row.changed_at == t2
      assert row.metadata == %{"page_id" => 5}
      assert ContentHashes.stored_hash(@ns, "https://a.test/1") == other
    end

    test "namespaces keep their own sources" do
      {:ok, :new, _} = ContentHashes.record(@ns, "k", "x")
      assert {:new, _} = ContentHashes.check("test:other", "k", "x")
      assert {:unchanged, _} = ContentHashes.check(@ns, "k", "x")
    end

    test "invalid namespaces and keys are refused" do
      assert {:error, :invalid_namespace} = ContentHashes.check("", "k", "x")
      assert {:error, :invalid_namespace} = ContentHashes.record(nil, "k", "x")
      assert {:error, :invalid_source_key} = ContentHashes.check(@ns, "", "x")

      assert {:error, :invalid_source_key} =
               ContentHashes.record(@ns, String.duplicate("k", 2_049), "x")

      refute ContentHashes.changed?("", "k", "x")
    end

    test "limits are in bytes, so a key of many-byte characters cannot overflow the index" do
      # 2 048 characters, 8 192 bytes: past what one B-tree entry may hold.
      wide = String.duplicate("😀", 2_048)
      assert {:error, :invalid_source_key} = ContentHashes.record(@ns, wide, "x")

      assert {:error, :invalid_namespace} =
               ContentHashes.record(String.duplicate("é", 200), "k", "x")

      # A caller's own hash must fit the column.
      assert {:error, :invalid_hash} =
               ContentHashes.record(@ns, "k", {:hash, String.duplicate("h", 101)})

      assert {:error, :invalid_hash} = ContentHashes.record(@ns, "k", {:hash, ""})

      # The largest key that is allowed is stored.
      assert {:ok, :new, _} = ContentHashes.record(@ns, String.duplicate("k", 2_048), "x")
    end
  end

  describe "unchecked_since/3, delete" do
    test "lists what a crawl did not see again, and forgets sources" do
      old = ~U[2026-11-01 00:00:00.000000Z]
      crawl = ~U[2026-11-02 00:00:00.000000Z]
      {:ok, _, _} = ContentHashes.record(@ns, "gone", "x", now: old)
      {:ok, _, _} = ContentHashes.record(@ns, "seen", "y", now: old)
      {:ok, _, _} = ContentHashes.record(@ns, "seen", "y", now: crawl)

      assert [%ContentHash{source_key: "gone"}] = ContentHashes.unchecked_since(@ns, crawl)

      assert :ok = ContentHashes.delete(@ns, "gone")
      assert ContentHashes.get(@ns, "gone") == nil
      assert ContentHashes.delete_namespace(@ns) == 1
      assert {:new, _} = ContentHashes.check(@ns, "seen", "y")
    end
  end
end
