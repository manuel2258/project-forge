defmodule Forge.ExploreTest do
  @moduledoc """
  What `Forge.Explore` decides without a machine: whether one can be asked, the file name a
  download offers, and the refusals a client is told (`docs/design/worker-tier.md` § Looking into a
  copy). The round trip is `ForgeWeb.WorkerChannelExploreTest`'s and the download's is
  `ForgeWeb.Api.BuildApiTest`'s.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures, only: [ticket_fixture: 0]
  import Forge.WarmFixtures, only: [kept!: 3]

  alias Forge.{Explore, FakeWorker, WarmBuilds}

  describe "status/1" do
    test "is outdated below protocol 18, and says so before it says not connected" do
      for protocol <- [nil, 0, 17] do
        assert Explore.status(%Forge.Workers.Worker{id: Ecto.UUID.generate(), protocol: protocol}) ==
                 {:error, :machine_outdated}
      end
    end

    test "is not connected for a machine with no channel, and ok for one with" do
      absent = %Forge.Workers.Worker{id: Ecto.UUID.generate(), protocol: 18}
      assert Explore.status(absent) == {:error, :machine_not_connected}

      worker = FakeWorker.connect()
      assert Explore.status(Forge.Workers.get!(worker.id)) == :ok
    end
  end

  describe "disposition_name/1" do
    test "keeps a name that is safe, and makes one that is not safe" do
      assert Explore.disposition_name("copy.tar") == "copy.tar"
      assert Explore.disposition_name("a b/c\\d\"e:f") == "a b_c_d_e_f"
      assert Explore.disposition_name("x\r\ny") == "x__y"
      assert Explore.disposition_name(<<"a", 255, "b">>) == "ab"

      # A hundred two-byte letters fill the 200 bytes.
      assert Explore.disposition_name(String.duplicate("é", 300)) == String.duplicate("é", 100)
    end

    test "is at most 200 bytes, whatever the characters are, and ends on a whole character" do
      # One letter and two thousand combining marks is one grapheme and over four thousand bytes.
      marked = "a" <> String.duplicate("\u0301", 2_000)
      assert byte_size(marked) == 4_001
      assert byte_size(Explore.disposition_name(marked)) <= 200
      assert String.valid?(Explore.disposition_name(marked))

      # Three-byte characters: 200 bytes would end in the middle of the 67th.
      name = Explore.disposition_name(String.duplicate("€", 300))
      assert byte_size(name) == 198
      assert String.valid?(name)
    end

    test "is download for a name that leaves nothing" do
      for name <- ["", "  ", ".", "..", nil, 3] do
        assert Explore.disposition_name(name) == "download"
      end
    end
  end

  describe "refusal/3 and missing/2" do
    setup do
      ticket = ticket_fixture()
      worker = FakeWorker.connect()
      %{ticket: ticket, worker: worker}
    end

    test "a machine that is away says until when its copy can be explored", ctx do
      kept!(ctx.ticket, ctx.worker, ago: 3600)
      [copy] = WarmBuilds.copies(ctx.ticket)

      assert {:explore, :machine_not_connected, %{explorable_until: until}} =
               Explore.refusal(ctx.ticket, copy, :machine_not_connected)

      assert %DateTime{} = until
    end

    test "a machine that does not have the copy says why, from the platform's own rows", ctx do
      old = kept!(ctx.ticket, ctx.worker, ago: 600)
      newer = kept!(ctx.ticket, ctx.worker, ago: 60)
      {:ok, copy} = WarmBuilds.copy(ctx.ticket, old.id)

      assert {:explore, :copy_gone, %{why: :replaced, replaced_by: by}} =
               Explore.refusal(ctx.ticket, copy, :no_copy)

      assert by == newer.id
    end

    test "any other code is itself", ctx do
      kept!(ctx.ticket, ctx.worker, [])
      [copy] = WarmBuilds.copies(ctx.ticket)
      assert Explore.refusal(ctx.ticket, copy, :not_a_folder) == {:explore, :not_a_folder, %{}}
    end

    test "a copy that is another ticket's is not found, not gone", ctx do
      theirs = kept!(ticket_fixture(), ctx.worker, [])
      assert Explore.missing(ctx.ticket, theirs.id) == :not_found
      assert Explore.missing(ctx.ticket, Ecto.UUID.generate()) == :not_found
    end

    test "a copy of this ticket that its machine no longer lists is gone", ctx do
      mine = kept!(ctx.ticket, ctx.worker, ago: 3 * 24 * 3600)
      assert {:explore, :copy_gone, %{why: :swept}} = Explore.missing(ctx.ticket, mine.id)
    end
  end
end
