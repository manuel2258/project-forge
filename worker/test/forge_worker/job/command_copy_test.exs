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

      assert {:ok, size} = CommandCopy.keep(root, key, worktree, facts())
      assert is_integer(size)

      assert {:ok, %{"job_id" => "j1", "command" => "test", "commit" => "abc", "epoch" => 0}} =
               CommandCopy.take(root, key, Path.join(root, "w2"))

      assert File.read!(Path.join(root, "w2/built")) == "first"
    end

    test "a copy kept under another epoch is not this ticket's any more",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts())

      assert :none = CommandCopy.take(root, %{key | epoch: 1}, Path.join(root, "w"))
      refute File.exists?(Path.join(root, "w"))
      assert CommandCopy.marker(root, key)
      refute CommandCopy.marker(root, %{key | epoch: 1})
    end

    test "another ticket's copy is never read", %{root: root, worktree: worktree, key: key} do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts())
      other = %{key | ticket: "5f0a6d1e-0000-4000-8000-000000000002"}

      assert :none = CommandCopy.take(root, other, Path.join(root, "w"))
    end

    test "a copy without its marker is no copy", %{root: root, worktree: worktree, key: key} do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts())
      File.rm!(CommandCopy.marker_path(root, key))

      assert :none = CommandCopy.take(root, key, Path.join(root, "w"))
    end

    test "a marker that is not JSON is no copy either", %{
      root: root,
      worktree: worktree,
      key: key
    } do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts())
      File.write!(CommandCopy.marker_path(root, key), "{nope")

      assert :none = CommandCopy.take(root, key, Path.join(root, "w"))
    end

    test "keeping replaces the copy, and the marker names the later command",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts("j1"))
      File.write!(Path.join(worktree, "built"), "second")
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts("j2"))

      assert {:ok, %{"job_id" => "j2"}} = CommandCopy.take(root, key, Path.join(root, "w"))
      assert File.read!(Path.join(root, "w/built")) == "second"
      assert Path.wildcard(Path.join([root, "volumes", "command", "*"])) |> length() == 2
    end

    test "a keep the machine cannot make leaves the copy and its marker as they were",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts("j1"))
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
      {:ok, _size} = CommandCopy.keep(root, later, worktree, facts("later"))
      File.write!(Path.join(worktree, "built"), "older")

      assert {:error, :superseded} = CommandCopy.keep(root, key, worktree, facts("older"))

      assert {:ok, %{"job_id" => "later"}} = CommandCopy.take(root, later, Path.join(root, "w"))
      assert File.read!(Path.join(root, "w/built")) == "first"
    end

    test "a keep that fails after its snapshot leaves no sibling behind",
         %{root: root, worktree: worktree, key: key} do
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts("j1"))

      Application.put_env(:forge_worker, :refuse_delete, CommandCopy.path(root, key))
      assert {:error, :refused} = CommandCopy.keep(root, key, worktree, facts("j2"))

      assert [] = Path.wildcard(Path.join([root, "volumes", "command", "*.keeping.*"]))
    end

    test "two commands of one ticket keep one after the other, and the last is the copy",
         %{root: root, worktree: worktree, key: key} do
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
      assert {:ok, _size} = Task.await(keeper)
      assert {:ok, %{"job_id" => "late"}} = CommandCopy.take(root, key, Path.join(root, "w"))
    end
  end

  describe "sweep/2" do
    test "removes a stale copy and its marker, keeps a fresh one, and returns the bytes freed",
         %{root: root, worktree: worktree, key: key} do
      stale = %{key | ticket: "5f0a6d1e-0000-4000-8000-000000000009"}
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts())
      {:ok, _size} = CommandCopy.keep(root, stale, worktree, facts())
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
      {:ok, _size} = CommandCopy.keep(root, key, worktree, facts())
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
end
