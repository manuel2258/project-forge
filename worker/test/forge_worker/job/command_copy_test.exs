defmodule ForgeWorker.Job.CommandCopyTest do
  @moduledoc """
  A ticket's command copy (`docs/design/worker-tier.md` § The command copy): what may be kept and
  used, under one lock per ticket, and swept like a ticket volume.

  Not async: the volume implementation is one application environment key for the node.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.CommandCopy
  alias ForgeWorker.RefusingVolume

  @ticket "5f0a6d1e-0000-4000-8000-000000000001"

  setup do
    Application.put_env(:forge_worker, :volume, RefusingVolume)

    on_exit(fn ->
      Application.delete_env(:forge_worker, :volume)
      Application.delete_env(:forge_worker, :refuse_snapshot)
      Application.delete_env(:forge_worker, :refuse_delete)
    end)

    root = tmp_dir("copy-root")
    worktree = tmp_dir("copy-worktree")
    File.write!(Path.join(worktree, "built"), "first")
    %{root: root, worktree: worktree, key: %{ticket: @ticket, epoch: 0}}
  end

  defp assignment(overrides \\ %{}) do
    Map.merge(
      %{
        "job_id" => uuid(),
        "git" => %{"branch" => "ticket/1"},
        "warm" => %{"ticket" => @ticket, "epoch" => 0},
        "spec" => %{"command" => %{"keep_build" => [0], "name" => "test"}}
      },
      overrides
    )
  end

  defp facts(job_id \\ "j1"), do: %{"job_id" => job_id, "command" => "test", "commit" => "abc"}

  describe "key/1" do
    test "is the ticket's id and epoch for a ticket's branch" do
      assert {:ok, %{ticket: @ticket, epoch: 0}} = CommandCopy.key(assignment())
    end

    test "is none for a branch that is not a ticket's, whatever else the assignment says" do
      for branch <- ["chat/abc", "ticket/x", "ticket/1/../2", "main", "ticket/1\n"] do
        assert :none = CommandCopy.key(assignment(%{"git" => %{"branch" => branch}})), branch
      end

      assert :none =
               CommandCopy.key(%{"git" => %{}, "warm" => %{"ticket" => @ticket, "epoch" => 0}})
    end

    test "is none for an id that is not a UUID, which would otherwise become a path" do
      for id <- ["../x", "..", @ticket <> "/..", "x", "", @ticket <> "\n", 7] do
        assert :none = CommandCopy.key(assignment(%{"warm" => %{"ticket" => id, "epoch" => 0}})),
               inspect(id)
      end
    end

    test "is none without `warm`, or with an epoch that is not a whole number" do
      assert :none = CommandCopy.key(Map.delete(assignment(), "warm"))

      for epoch <- ["0", 1.5, nil] do
        assert :none =
                 CommandCopy.key(
                   assignment(%{"warm" => %{"ticket" => @ticket, "epoch" => epoch}})
                 ),
               inspect(epoch)
      end
    end
  end

  describe "statuses/1 and warm_start?/1" do
    test "keep only a list of exit statuses" do
      assert CommandCopy.statuses(assignment()) == [0]

      assert CommandCopy.statuses(
               put_in(assignment(), ["spec", "command", "keep_build"], [0, 256])
             ) == []

      assert CommandCopy.statuses(put_in(assignment(), ["spec", "command", "keep_build"], "*")) ==
               []

      assert CommandCopy.statuses(put_in(assignment(), ["spec", "command"], %{})) == []
      assert CommandCopy.statuses(%{}) == []
    end

    test "start from the copy unless the command says false" do
      assert CommandCopy.warm_start?(assignment())

      assert CommandCopy.warm_start?(
               put_in(assignment(), ["spec", "command", "warm_start"], true)
             )

      refute CommandCopy.warm_start?(
               put_in(assignment(), ["spec", "command", "warm_start"], false)
             )
    end
  end

  describe "keep/4 and take/3" do
    test "a kept tree is what the next command snapshots, with the marker that says who left it",
         %{root: root, worktree: worktree, key: key} do
      assert :none = CommandCopy.take(root, key, Path.join(root, "w1"))

      assert {:ok, size, nil} = CommandCopy.keep(root, key, worktree, facts())
      assert is_integer(size)

      assert {:ok, %{"job_id" => "j1", "command" => "test", "commit" => "abc", "epoch" => 0}} =
               CommandCopy.take(root, key, Path.join(root, "w2"))

      assert File.read!(Path.join(root, "w2/built")) == "first"
    end

    test "a copy kept under another epoch is not this ticket's any more",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts())

      assert :none = CommandCopy.take(root, %{key | epoch: 1}, Path.join(root, "w"))
      refute File.exists?(Path.join(root, "w"))
      assert CommandCopy.marker(root, key)
      refute CommandCopy.marker(root, %{key | epoch: 1})
    end

    test "another ticket's copy is never read", %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts())
      other = %{key | ticket: "5f0a6d1e-0000-4000-8000-000000000002"}

      assert :none = CommandCopy.take(root, other, Path.join(root, "w"))
    end

    test "a copy without its marker is no copy", %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts())
      File.rm!(CommandCopy.marker_path(root, key))

      assert :none = CommandCopy.take(root, key, Path.join(root, "w"))
    end

    test "a marker that is not JSON is no copy either", %{
      root: root,
      worktree: worktree,
      key: key
    } do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts())
      File.write!(CommandCopy.marker_path(root, key), "{nope")

      assert :none = CommandCopy.take(root, key, Path.join(root, "w"))
    end

    test "keeping replaces the copy, and the marker names the later command",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts("j1"))
      File.write!(Path.join(worktree, "built"), "second")
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts("j2"))

      assert {:ok, %{"job_id" => "j2"}} = CommandCopy.take(root, key, Path.join(root, "w"))
      assert File.read!(Path.join(root, "w/built")) == "second"
      assert Path.wildcard(Path.join([root, "volumes", "command", "*"])) |> length() == 2
    end

    test "a keep the machine cannot make leaves the copy and its marker as they were",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts("j1"))
      marker = File.read!(CommandCopy.marker_path(root, key))

      Application.put_env(:forge_worker, :refuse_snapshot, "copy-worktree")
      assert {:error, :refused} = CommandCopy.keep(root, key, worktree, facts("j2"))

      assert File.read!(CommandCopy.marker_path(root, key)) == marker
      assert File.read!(Path.join(CommandCopy.path(root, key), "built")) == "first"
    end

    # A command assigned before a Clear can finish after one assigned after it: its older tree must
    # not replace the newer copy, which is the one the platform names.
    test "a keep from an earlier epoch does not replace a copy of a later one",
         %{root: root, worktree: worktree, key: key} do
      later = %{key | epoch: 1}
      {:ok, _size, _folders} = CommandCopy.keep(root, later, worktree, facts("later"))
      File.write!(Path.join(worktree, "built"), "older")

      assert {:error, :superseded} = CommandCopy.keep(root, key, worktree, facts("older"))

      assert {:ok, %{"job_id" => "later"}} = CommandCopy.take(root, later, Path.join(root, "w"))
      assert File.read!(Path.join(root, "w/built")) == "first"
    end

    test "a keep that fails after its snapshot leaves no sibling behind",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts("j1"))

      Application.put_env(:forge_worker, :refuse_delete, CommandCopy.path(root, key))
      assert {:error, :refused} = CommandCopy.keep(root, key, worktree, facts("j2"))

      assert [] = Path.wildcard(Path.join([root, "volumes", "command", "*.keeping.*"]))
    end

    test "two commands of one ticket keep one after the other, and the last is the copy",
         %{root: root, key: key} do
      # The first holds the lock while the second asks for it: the order is the first's keep, then
      # the second's, not an interleaving that could leave a marker naming another copy's tree.
      test = self()
      second_tree = tmp_dir("second-tree")
      File.write!(Path.join(second_tree, "built"), "second")

      holder =
        spawn_link(fn ->
          :global.trans({{CommandCopy, key.ticket}, self()}, fn ->
            send(test, :holding)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :holding

      keeper =
        Task.async(fn -> CommandCopy.keep(root, key, second_tree, facts("late")) end)

      refute Task.yield(keeper, 200)
      refute File.exists?(CommandCopy.marker_path(root, key))

      send(holder, :release)
      assert {:ok, _size, _folders} = Task.await(keeper)
      assert {:ok, %{"job_id" => "late"}} = CommandCopy.take(root, key, Path.join(root, "w"))
    end
  end

  describe "sweep/2" do
    test "removes a stale copy and its marker, keeps a fresh one, and returns the bytes freed",
         %{root: root, worktree: worktree, key: key} do
      stale = %{key | ticket: "5f0a6d1e-0000-4000-8000-000000000009"}
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts())
      {:ok, _size, _folders} = CommandCopy.keep(root, stale, worktree, facts())
      File.touch!(CommandCopy.path(root, stale), {{2020, 1, 1}, {0, 0, 0}})

      freed = CommandCopy.sweep(root, :timer.hours(48))

      assert freed > 0
      refute File.exists?(CommandCopy.path(root, stale))
      refute File.exists?(CommandCopy.marker_path(root, stale))
      assert File.dir?(CommandCopy.path(root, key))
      assert CommandCopy.marker(root, key)
    end

    test "touch says the ticket ran a command, so a used copy is not swept",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts())
      File.touch!(CommandCopy.path(root, key), {{2020, 1, 1}, {0, 0, 0}})

      :ok = CommandCopy.touch(root, key)

      assert CommandCopy.sweep(root, :timer.hours(48)) == 0
      assert CommandCopy.marker(root, key)
    end

    test "touching a ticket with no copy makes none", %{root: root, key: key} do
      assert :ok = CommandCopy.touch(root, key)
      refute File.exists?(CommandCopy.path(root, key))
    end
  end

  # `docs/design/worker-tier.md` § Looking into a copy: a copy someone has open is held, a keep
  # moves it aside, the sweep leaves it, and the hold lapses ten minutes after the last action.
  describe "a copy someone is looking at" do
    @first "5f0a6d1e-0000-4000-8000-0000000000a1"
    @second "5f0a6d1e-0000-4000-8000-0000000000a2"

    defp lapse(root, ticket, job, seconds_ago \\ 700) do
      File.touch!(
        CommandCopy.hold_path(root, ticket, job),
        System.os_time(:second) - seconds_ago
      )
    end

    test "opening finds the ticket's current copy and holds it", %{
      root: root,
      worktree: worktree,
      key: key
    } do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))

      refute CommandCopy.held?(root, @ticket, @first)
      assert {:ok, dir} = CommandCopy.open(root, @ticket, @first)
      assert dir == CommandCopy.path(root, key)
      assert CommandCopy.held?(root, @ticket, @first)
    end

    test "a copy of another job, another ticket, or that is not an id is not found, and is not held",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))

      assert :error = CommandCopy.open(root, @ticket, @second)
      assert :error = CommandCopy.open(root, "5f0a6d1e-0000-4000-8000-000000000002", @first)
      assert :error = CommandCopy.open(root, "../#{@ticket}", @first)
      assert :error = CommandCopy.open(root, @ticket, "../../etc")
      refute CommandCopy.held?(root, @ticket, @second)
      refute File.exists?(Path.join([root, "volumes", "hold"]))
    end

    test "a copy of another epoch, which a Clear left, can still be looked at",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))

      refute CommandCopy.marker(root, %{key | epoch: 1})
      assert {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
    end

    test "a keep while the copy is held moves it aside, and it is still answered",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      File.write!(Path.join(worktree, "built"), "second")

      assert {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@second))

      assert {:ok, %{"job_id" => @second}} = CommandCopy.take(root, key, Path.join(root, "w"))
      assert File.read!(Path.join(root, "w/built")) == "second"

      assert {:ok, aside} = CommandCopy.open(root, @ticket, @first)
      assert aside == CommandCopy.held_path(root, @ticket, @first)
      assert File.read!(Path.join(aside, "built")) == "first"
      refute String.starts_with?(aside, Path.join([root, "volumes", "command"]))
    end

    test "a keep while the copy is not held deletes it", %{
      root: root,
      worktree: worktree,
      key: key
    } do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      lapse(root, @ticket, @first)

      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@second))

      assert :error = CommandCopy.open(root, @ticket, @first)
      refute File.exists?(CommandCopy.held_path(root, @ticket, @first))
    end

    test "the two-day sweep leaves a held copy and takes it once the hold has lapsed",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      File.touch!(CommandCopy.path(root, key), {{2020, 1, 1}, {0, 0, 0}})

      assert CommandCopy.sweep(root, :timer.hours(48)) == 0
      assert File.dir?(CommandCopy.path(root, key))

      lapse(root, @ticket, @first)
      assert CommandCopy.sweep(root, :timer.hours(48)) > 0
      refute File.exists?(CommandCopy.path(root, key))
    end

    test "release removes a moved-aside copy whose hold has lapsed, and not one that has not",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@second))
      aside = CommandCopy.held_path(root, @ticket, @first)

      assert CommandCopy.release_holds(root) == 0
      assert File.dir?(aside)

      lapse(root, @ticket, @first)
      assert CommandCopy.release_holds(root) > 0
      refute File.exists?(aside)
      refute File.exists?(CommandCopy.hold_path(root, @ticket, @first))
      assert File.dir?(CommandCopy.path(root, key))
    end

    test "an action renews the hold, so a download that outlasts ten minutes is not cut off",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      lapse(root, @ticket, @first, 590)
      assert CommandCopy.held?(root, @ticket, @first)

      :ok = CommandCopy.touch_hold(root, @ticket, @first)
      lapse(root, @ticket, @first, 5)
      assert CommandCopy.held?(root, @ticket, @first)

      lapse(root, @ticket, @first, 700)
      refute CommandCopy.held?(root, @ticket, @first)
      assert CommandCopy.release_holds(root) == 0
      refute File.exists?(CommandCopy.hold_path(root, @ticket, @first))
    end

    test "a live hold survives the minute's tick, and only a lapsed one is dropped",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      hold = CommandCopy.hold_path(root, @ticket, @first)

      assert CommandCopy.release_holds(root) == 0
      assert File.exists?(hold)

      lapse(root, @ticket, @first)
      assert CommandCopy.release_holds(root) == 0
      refute File.exists?(hold)
    end

    # **The ids are matched as UUIDs before either becomes a path**: the marker here does name the
    # job, and the directory is there, so only the match refuses it.
    test "an id that is not a UUID finds nothing, though a copy is there that names it",
         %{root: root} do
      copy = Path.join([root, "volumes", "command", "a"])
      File.mkdir_p!(copy)
      File.write!(copy <> ".json", ~s({"job_id": "b", "epoch": 0}))

      assert CommandCopy.open(root, "a", "b") == :error
    end

    # Sizing a large tree takes minutes and every reader waits for the ticket's lock, so it is done
    # before the lock is taken: while the keep sizes, the copy that is there still answers.
    test "a keep that is still sizing does not hold the lock a reader needs",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))

      test = self()

      Application.put_env(:forge_worker, :copy_sizer, fn _tree, _ignored ->
        send(test, {:sizing, self()})

        receive do
          :go -> {7, nil}
        end
      end)

      on_exit(fn -> Application.delete_env(:forge_worker, :copy_sizer) end)

      keeper = Task.async(fn -> CommandCopy.keep(root, key, worktree, facts(@second)) end)
      assert_receive {:sizing, sizer}

      reader = Task.async(fn -> CommandCopy.open(root, @ticket, @first) end)
      assert {:ok, {:ok, _dir}} = Task.yield(reader, 2_000) || Task.shutdown(reader)

      send(sizer, :go)
      assert {:ok, 7, nil} = Task.await(keeper)
    end

    test "a keep sizes the copy's ignored folders in the same walk",
         %{root: root, worktree: worktree, key: key} do
      File.mkdir_p!(Path.join(worktree, "target"))
      File.write!(Path.join(worktree, "target/obj"), :binary.copy("x", 20_000))

      assert {:ok, total, %{"folders" => [%{"path" => "target", "bytes" => bytes}]} = folders} =
               CommandCopy.keep(root, key, worktree, facts(@first), [{"target", :dir}])

      assert bytes >= 20_000
      assert total == bytes + folders["rest"]
    end
  end

  describe "a copy someone is looking at, when the machine will not cooperate" do
    @first "5f0a6d1e-0000-4000-8000-0000000000e1"
    @second "5f0a6d1e-0000-4000-8000-0000000000e2"

    test "a keep whose old copy cannot be moved aside deletes it and still keeps",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)

      # Where the old copy would go is a folder that is not empty: the rename is refused.
      blocked = CommandCopy.held_path(root, @ticket, @first)
      File.mkdir_p!(Path.join(blocked, "in the way"))

      assert {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@second))

      assert {:ok, %{"job_id" => @second}} = CommandCopy.take(root, key, Path.join(root, "w"))
      assert File.dir?(Path.join(root, "w"))
    end

    test "release leaves what it did not put there, and what it cannot delete",
         %{root: root, worktree: worktree, key: key} do
      junk = Path.join([root, "volumes", "held", "not-a-copy"])
      File.mkdir_p!(junk)

      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@second))
      aside = CommandCopy.held_path(root, @ticket, @first)

      File.touch!(CommandCopy.hold_path(root, @ticket, @first), System.os_time(:second) - 700)
      Application.put_env(:forge_worker, :refuse_delete, aside)

      assert CommandCopy.release_holds(root) == 0
      assert File.dir?(aside)
      assert File.dir?(junk)

      Application.delete_env(:forge_worker, :refuse_delete)
      assert CommandCopy.release_holds(root) > 0
      refute File.exists?(aside)
      assert File.dir?(junk)
    end

    test "a hold that cannot be written is a warning and not a failed request",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size, _folders} = CommandCopy.keep(root, key, worktree, facts(@first))
      File.mkdir_p!(Path.join(root, "volumes"))
      File.write!(Path.join([root, "volumes", "hold"]), "a file where the folder should be")

      assert {:ok, _dir} = CommandCopy.open(root, @ticket, @first)
      refute CommandCopy.held?(root, @ticket, @first)
    end

    test "the sweep takes a stale directory that is not a ticket's, which no one can hold",
         %{root: root} do
      junk = Path.join([root, "volumes", "command", "not-a-ticket"])
      File.mkdir_p!(junk)
      File.write!(Path.join(junk, "x"), "x")
      File.touch!(junk, {{2020, 1, 1}, {0, 0, 0}})

      assert CommandCopy.sweep(root, :timer.hours(48)) > 0
      refute File.exists?(junk)
    end

    test "a copy whose marker is for a job that is not an id is never held", %{root: root} do
      copy = Path.join([root, "volumes", "command", @ticket])
      File.mkdir_p!(copy)
      File.write!(Path.join(copy, "built"), String.duplicate("x", 8192))
      File.write!(copy <> ".json", ~s({"job_id": "j1", "epoch": 0}))
      File.touch!(copy, {{2020, 1, 1}, {0, 0, 0}})

      assert CommandCopy.sweep(root, :timer.hours(48)) > 0
      refute File.exists?(copy)
    end
  end
end
