defmodule ForgeWorker.Archive.MountTest do
  @moduledoc """
  What the kernel is asked to mount, and how a mount left behind is found
  (`docs/design/archive.md` § The worker's side).
  """

  # `PATH` is the process's, shared: the kernel's `mount` is a script of the test's own.
  use ExUnit.Case, async: false

  alias ForgeWorker.Archive.Mount

  test "the kernel's options refuse writes, setuid, devices and execution" do
    options = Mount.options()

    for option <- ~w(ro nosuid nodev noexec trans=unix version=9p2000.L cache=none),
        do: assert(option in options)
  end

  test "mounted finds 9p mounts and no others, and reads an escaped path" do
    text = """
    36 35 98:0 / /mnt1 rw,noatime shared:1 - ext3 /dev/root rw
    41 29 0:44 / /var/lib/forge/jobs/a/archive ro,nosuid,nodev,noexec - 9p /tmp/archive.sock ro,access=any
    42 29 0:45 / /var/lib/forge/jobs/b\\040c/archive ro - 9p /tmp/x ro
    garbage
    """

    assert Mount.mounted(text) == [
             "/var/lib/forge/jobs/a/archive",
             "/var/lib/forge/jobs/b c/archive"
           ]
  end

  test "a machine with no mount says so in one file" do
    dir = Path.join(System.tmp_dir!(), "forge-none-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    refute Mount.None.serves?()
    assert Mount.None.mount(nil, dir) == :ok
    assert File.ls!(dir) == ["README.md"]
    assert File.read!(Path.join(dir, "README.md")) =~ "not mounted"
    assert Mount.None.unmount(dir) == :ok
    assert Mount.NineP.serves?()
  end

  test "unmounting what is not mounted is not an error" do
    assert Mount.NineP.unmount("/nonexistent/archive") == :ok
  end

  describe "the kernel's mount" do
    setup do
      bin = Path.join(System.tmp_dir!(), "forge-mount-bin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end)

      %{bin: bin, record: Path.join(bin, "args")}
    end

    defp fake_mount(%{bin: bin, record: record}, status) do
      script = Path.join(bin, "mount")

      File.write!(
        script,
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{record}\necho refused >&2\nexit #{status}\n"
      )

      File.chmod!(script, 0o755)
    end

    test "is asked for a read-only 9p mount of the socket, with the options that refuse more",
         context do
      fake_mount(context, 0)

      assert Mount.NineP.mount("/w/archive.sock", "/j/archive") == :ok

      assert File.read!(context.record) |> String.split("\n", trim: true) ==
               [
                 "-t",
                 "9p",
                 "-o",
                 Enum.join(Mount.options(), ","),
                 "/w/archive.sock",
                 "/j/archive"
               ]
    end

    test "that the kernel refuses is an error with what it said", context do
      fake_mount(context, 32)

      assert Mount.NineP.mount("/w/archive.sock", "/j/archive") ==
               {:error, {:mount, 32, "refused"}}
    end
  end
end
