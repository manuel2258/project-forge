defmodule Forge.ImageBuilderScriptTest do
  @moduledoc """
  The builder's first-boot script, as far as a machine that is not one can check it: the
  write-and-verify step against a file, and the one thing that matters about it — **it powers
  off only after reading back what it wrote and finding it to be the checksum the platform was
  built knowing** (`docs/design/provisioning.md` § Putting the release's image into an account).

  The chroot, the sysrq sequence and the download are not run here and the note says so.
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

  # `write_and_verify` is the only part run here. These pin the rest of the script by what it says,
  # because the lines that keep a bad image from being written are not reached by a test that
  # skips the download and the staging.
  test "the script says it checks the digest, keeps the machine on after a failure and masks poweroff" do
    script = File.read!(@script)
    assert script =~ ~s(sha256sum -c -)
    assert script =~ ~s(fetch || stay)
    assert script =~ ~s(stage || stay)

    assert script =~
             "systemctl mask poweroff.target halt.target reboot.target ctrl-alt-del.target"
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
