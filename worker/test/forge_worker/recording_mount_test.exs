defmodule ForgeWorker.RecordingMountTest do
  @moduledoc """
  The test mount tells each test of its own folders and of no others
  (`ForgeWorker.RecordingMount`): the archive's lifecycle tests were failing because it told
  whoever had last written the application environment.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Archive.Mount
  alias ForgeWorker.RecordingMount

  test "a test hears of the folders under its root, and not of another test's" do
    mine = tmp_dir("mount-mine")
    theirs = tmp_dir("mount-theirs")
    RecordingMount.watch(mine)

    # Another test, which `watch/2` cannot be called from: it ends with the test that called it.
    on_exit(fn -> RecordingMount.unwatch(theirs) end)

    other =
      Task.async(fn ->
        :ets.insert(RecordingMount, {theirs, self(), []})
        :ok = Mount.impl().unmount(Path.join(theirs, "archive"))
        receive do: ({:unmounted, folder} -> folder)
      end)

    :ok = Mount.impl().unmount(Path.join(mine, "archive"))
    # A directory whose name merely starts with this test's root is not under it.
    :ok = Mount.impl().unmount(Path.join(mine <> "-sibling", "archive"))

    assert Task.await(other) == Path.join(theirs, "archive")
    assert_received {:unmounted, folder}
    assert folder == Path.join(mine, "archive")
    refute_received {:unmounted, _folder}
  end

  test "a folder under no root is `Mount.None`'s: nothing mounts, nobody is told" do
    folder = Path.join(tmp_dir("mount-nobody"), "archive")
    File.mkdir_p!(folder)

    refute Mount.impl().serves?(folder)
    assert Mount.impl().mount(nil, folder) == :ok
    assert File.exists?(Path.join(folder, "README.md"))
    assert Mount.impl().unmount(folder) == :ok
    refute_received {:unmounted, _folder}
  end

  test "the options say whether there is a server and what a mount answers" do
    root = tmp_dir("mount-options")
    RecordingMount.watch(root, serves: false, mount: {:error, :boom})
    folder = Path.join(root, "archive")

    refute Mount.impl().serves?(folder)
    assert Mount.impl().mount("/socket", folder) == {:error, :boom}
    assert_received {:mounted, "/socket", ^folder}
  end
end
