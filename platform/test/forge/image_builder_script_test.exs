defmodule Forge.ImageBuilderScriptTest do
  @moduledoc """
  The builder's first-boot script, as far as a machine that is not one can check it: the
  write-and-verify step against a file, the program `stage` writes for systemd to hand PID 1 to,
  run for real against stub tools, and the one thing that matters about both — **the machine powers
  off only after reading back what it wrote and finding it to be the checksum the platform was
  built knowing** (`docs/design/provisioning.md` § Putting the release's image into an account).

  The download, systemd's hand-over at power-off and the sysrq power-off are not run here: they ran
  on a real Hetzner builder and a local Debian 12 VM, and the note says what was seen.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../priv/hetzner/image-builder.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "builder-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    raw = :crypto.strong_rand_bytes(100_000)
    File.write!(Path.join(dir, "raw"), raw)
    {_, 0} = System.cmd("gzip", ["-kn", Path.join(dir, "raw")])

    %{
      dir: dir,
      raw: raw,
      sha: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
      size: byte_size(raw)
    }
  end

  defp write_and_verify(c, sha, gz \\ "raw.gz") do
    command =
      ~s(. "$SCRIPT"; write_and_verify "$DIR/#{gz}" "$DIR/disk" "$SIZE" "$SHA" "$DIR/trigger")

    System.cmd("sh", ["-c", command],
      env: [
        {"SCRIPT", @script},
        {"DIR", c.dir},
        {"SIZE", to_string(c.size)},
        {"SHA", sha},
        {"FORGE_BUILDER_SOURCE_ONLY", "1"},
        {"FORGE_BUILDER_DD_FLAGS", ""}
      ],
      stderr_to_stdout: true
    )
  end

  test "powers off after a written disk reads back as the checksum", c do
    assert {_, 0} = write_and_verify(c, c.sha)
    assert File.read!(Path.join(c.dir, "disk")) == c.raw
    assert File.read!(Path.join(c.dir, "trigger")) == "o\n"
  end

  test "never powers off when the disk does not read back as the checksum", c do
    wrong = String.duplicate("0", 64)
    assert {_, status} = write_and_verify(c, wrong)
    assert status != 0
    refute File.exists?(Path.join(c.dir, "trigger"))
  end

  test "never powers off on an image that is cut short", c do
    gz = File.read!(Path.join(c.dir, "raw.gz"))
    File.write!(Path.join(c.dir, "cut.gz"), binary_part(gz, 0, div(byte_size(gz), 2)))

    assert {_, status} = write_and_verify(c, c.sha, "cut.gz")
    assert status != 0
    refute File.exists?(Path.join(c.dir, "trigger"))
  end

  # `main` and `fetch` are not run here. These pin them by what they say, because the lines that keep
  # a bad image from being written are not reached by a test that skips the download.
  test "the script says it checks the digest, keeps the machine on after a failure and masks poweroff" do
    script = File.read!(@script)
    assert script =~ ~s(sha256sum -c -)
    assert script =~ ~s(fetch || stay)
    assert script =~ ~s(stage "${FORGE_BUILDER_DEVICE:-/dev/sda}" || stay)

    assert script =~
             "systemctl mask poweroff.target halt.target reboot.target ctrl-alt-del.target"
  end

  # systemd-shutdown looks for its program at this path and no other; staged anywhere else, it never
  # runs and the machine powers off with nothing written — and the `[ -x ]` below, asked of the
  # wrong path, would not notice.
  test "the script stages the writer where systemd-shutdown looks for it" do
    assert File.read!(@script) =~ ~r/^STAGE=\/run\/initramfs$/m
  end

  # Debian mounts /run noexec, and systemd-shutdown's access(X_OK) on the staged writer then fails:
  # it skips the hand-over silently and powers off with nothing written, which reads as success.
  test "the script makes /run executable before staging the writer there" do
    script = File.read!(@script)
    assert script =~ "mount -o remount,exec,size=3g /run || return 1"
  end

  # The same question systemd-shutdown asks, before the only power-off the script requests; without
  # it a writer systemd will not run turns into an unwritten disk the platform snapshots.
  test "the script powers off only after finding the staged writer executable" do
    lines = String.split(File.read!(@script), "\n")
    guard = Enum.find_index(lines, &(&1 =~ ~s([ -x "$STAGE/shutdown" ] || stay)))
    unmask = Enum.find_index(lines, &(&1 =~ "systemctl unmask poweroff.target"))
    poweroff = Enum.find_index(lines, &(&1 =~ "systemctl --no-block poweroff"))
    assert guard && unmask && poweroff
    assert guard < unmask and unmask < poweroff
  end

  @tools ~w(dash gzip dd head sha256sum cut sync cat sleep mount umount)

  # `stage` run for real, with stub tools ahead of the real ones on PATH — and `extra` stubs beside
  # them, each a name and a script body.
  defp stage(c, extra \\ []) do
    stubs = Path.join(c.dir, "stubs")
    File.mkdir_p!(stubs)

    for {tool, body} <- Enum.map(@tools, &{&1, "exit 0"}) ++ extra do
      path = Path.join(stubs, tool)
      File.write!(path, "#!/bin/sh\n#{body}\n")
      File.chmod!(path, 0o755)
    end

    stage = Path.join(c.dir, "stage")

    {_, status} =
      System.cmd(
        "bash",
        ["-c", ~s(. "$SCRIPT"; STAGE="$STAGE_DIR"; stage /dev/sdz)],
        env: [
          {"SCRIPT", @script},
          {"STAGE_DIR", stage},
          {"PATH", stubs <> ":" <> System.get_env("PATH")},
          {"FORGE_BUILDER_SOURCE_ONLY", "1"}
        ],
        stderr_to_stdout: true
      )

    {status, stage}
  end

  # A loader or library the writer needs and does not have makes its execve fail, and systemd then
  # powers off with nothing written: staging that could not copy one is a failure, not a warning.
  test "staging fails when a library cannot be copied", c do
    missing = ~s{echo "libgone.so => /nonexistent/libgone.so (0x0)"}
    assert {status, _stage} = stage(c, [{"ldd", missing}])
    assert status != 0
  end

  describe "the writer systemd hands PID 1 to" do
    # What is checked is the program `stage` writes rather than the lines that write it.
    setup c do
      {0, stage} = stage(c)
      shutdown = Path.join(stage, "shutdown")
      %{stage: stage, shutdown: shutdown, lines: String.split(File.read!(shutdown), "\n")}
    end

    # It runs with PATH=/bin in a root holding nothing else, so a tool left out is a writer that
    # stops at its first use of it.
    test "has every tool it calls staged beside it", c do
      for tool <- @tools, do: assert(File.exists?(Path.join([c.stage, "bin", tool])), tool)
    end

    # Given a path that is not a block device, `dd` makes a file in memory, which reads back as the
    # checksum and powers the machine off with the disk untouched.
    test "refuses to write to anything but a block device", c do
      guard =
        Enum.find_index(
          c.lines,
          &(&1 == ~s([ -b '/dev/sdz' ] || stay '/dev/sdz is not a block device'))
        )

      devtmpfs = Enum.find_index(c.lines, &(&1 =~ "mount -t devtmpfs devtmpfs /dev"))
      write = Enum.find_index(c.lines, &String.starts_with?(&1, "write_and_verify /image.gz"))
      assert guard && devtmpfs && write
      assert devtmpfs < guard and guard < write
    end

    test "stays on when it cannot mount proc, where the power-off is written", c do
      assert Enum.any?(
               c.lines,
               &(&1 ==
                   ~s([ -e /proc/self/mounts ] || mount -t proc proc /proc || stay "proc could not be mounted"))
             )
    end

    # The power-off is `write_and_verify`'s last line, after the comparison, and the writer touches
    # the trigger nowhere else: a second write, however spelt, is a second way to "succeed".
    test "touches the sysrq trigger only through write_and_verify", c do
      assert [line] = Enum.filter(c.lines, &(&1 =~ "sysrq-trigger"))
      assert String.starts_with?(line, "write_and_verify /image.gz ")
      assert [_] = Enum.filter(c.lines, &(&1 =~ ~s($trigger)))
    end

    test "is executable and runs from what was staged", c do
      assert %{mode: mode} = File.stat!(c.shutdown)
      assert Bitwise.band(mode, 0o111) == 0o111
      assert ["#!/bin/dash", "PATH=/bin" | _] = c.lines
    end

    # Lazily detached, a filesystem something still held would go on writing into the image, which
    # is the failure the hand-over exists to remove.
    test "unmounts the old root, not lazily, before it writes", c do
      umount = Enum.find_index(c.lines, &String.starts_with?(&1, "umount "))
      write = Enum.find_index(c.lines, &String.starts_with?(&1, "write_and_verify /image.gz"))
      assert umount && write && umount < write

      assert Enum.at(c.lines, umount) ==
               ~s(umount -R /oldroot || stay "the old root could not be unmounted")
    end

    test "writes the device it was given, with the release's size and checksum", c do
      assert Enum.any?(
               c.lines,
               &(&1 =~
                   ~r{^write_and_verify /image\.gz '/dev/sdz' '@RAW_SIZE@' '@RAW_SHA256@' /proc/sysrq-trigger \|\|$})
             )
    end

    # The sysrq power-off lands a moment after the write returns; saying it did not take at once put
    # a false failure on the console of a builder that was about to succeed.
    test "waits for the power-off before saying it did not take", c do
      tail = c.lines |> Enum.reject(&(&1 == "")) |> Enum.take(-2)
      assert tail == ["sleep 60", ~s(stay "powering off did not take")]
    end
  end

  # The only line that can end the machine is the last one of write_and_verify, and it is after
  # the comparison. Anything else writing `o` to a trigger would be a second way to "succeed".
  test "the only power-off in the script is after the comparison" do
    lines = String.split(File.read!(@script), "\n")
    assert [index] = for({line, i} <- Enum.with_index(lines), line =~ ~r/\becho o\b/, do: i)
    before = lines |> Enum.take(index) |> Enum.reject(&(&1 == "")) |> List.last()
    assert before =~ ~s(|| return 1)
  end
end
