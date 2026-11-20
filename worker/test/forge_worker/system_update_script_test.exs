defmodule ForgeWorker.SystemUpdateScriptTest do
  @moduledoc """
  The privileged half of a machine's self-update (`nix/system-update.sh`, with `nix/boot-menu.sh`),
  run against stand-ins for everything that needs a machine — `curl`, `losetup`, `mount`,
  `btrfstune`, `nix`, `nix-store`, `systemctl`, `df`, `mountpoint` — and **real `gzip` and
  `sha256sum`**, so the checks that matter are the real ones: the checksum of what was downloaded
  and the raw disk's size and checksum.

  **Nothing here boots anything.** What a real kernel does with the boot entries, a real loop
  device and a real registry are `docs/design/worker-tier.md` § Updating a permanent machine,
  *Not verified here*.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../../nix/system-update.sh", __DIR__)
  @menu Path.expand("../../../nix/boot-menu.sh", __DIR__)
  @repository "ghcr.io/example/forge-worker-image"
  @old_hash "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @new_hash "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @build "wwwwwwwwwwww"

  setup do
    base = Path.join(System.tmp_dir!(), "system-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    dirs =
      for name <- ~w(update esp gcroots bin store), into: %{} do
        path = Path.join(base, name)
        File.mkdir_p!(path)
        {name, path}
      end

    layout = Path.join(base, "layout")
    File.write!(layout, "2\n")

    # The running system, linked as `/run/current-system` is, and enabled in the menu the way the
    # image's own build enables it.
    old = system(base, @old_hash, "old")
    run_link = Path.join(base, "current-system")
    File.ln_s!(old, run_link)
    {_out, 0} = System.cmd("bash", [@menu, dirs["esp"], "stage", @old_hash, old])
    {_out, 0} = System.cmd("bash", [@menu, dirs["esp"], "enable", @old_hash])

    stand_ins(dirs["bin"])

    %{
      base: base,
      dirs: dirs,
      layout: layout,
      old: old,
      run_link: run_link,
      calls: Path.join(base, "calls.log")
    }
  end

  # A NixOS system as the boot menu reads one: a kernel, an initrd, the parameters.
  defp system(base, hash, name) do
    dir = Path.join([base, "nix", "store", "#{hash}-nixos-system-#{name}"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "kernel"), "kernel of #{name}")
    File.write!(Path.join(dir, "initrd"), "initrd of #{name}")
    File.write!(Path.join(dir, "kernel-params"), "console=ttyS0 root=fstab")
    dir
  end

  defp stand_ins(bin) do
    script = fn name, body ->
      path = Path.join(bin, name)
      File.write!(path, "#!/usr/bin/env bash\n" <> body)
      File.chmod!(path, 0o755)
    end

    # Serves the token and each blob by digest from `FAKE_DIR`.
    script.("curl", """
    printf 'curl %s\\n' "$*" >> "$FAKE_CALLS"
    out=
    url=
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out=$2; shift 2 ;;
        -H|--max-time|--proto|--proto-redir) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
      esac
    done
    case "$url" in
      */token\\?*) src=$FAKE_DIR/token ;;
      */blobs/*) src=$FAKE_DIR/blob-${url##*/blobs/sha256:} ;;
    esac
    [ -f "$src" ] || { echo "curl: (22) 404" >&2; exit 22; }
    if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
    """)

    script.("df", """
    echo "Avail"
    echo "${FAKE_AVAILABLE:-100000000000}"
    """)

    script.("nix-store", """
    printf 'nix-store %s\\n' "$*" >> "$FAKE_CALLS"
    case "$*" in
      *--gc*) exit 0 ;;
      *--load-db*) cat > /dev/null ;;
      *-qR*)
        printf '%s\\n' "/nix/store/${FAKE_WORKER_HASH:-wwwwwwwwwwww}aaaaaaaaaaaaaaaaaaaa-forge-worker-0.23.0" \\
          "/nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-glibc-2.40"
        if [ -n "${FAKE_TWO_WORKERS:-}" ]; then
          echo "/nix/store/qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq-forge-worker-0.22.0"
        fi
        ;;
    esac
    """)

    script.("nix", """
    printf 'nix %s\\n' "$*" >> "$FAKE_CALLS"
    """)

    script.("losetup", """
    printf 'losetup %s\\n' "$*" >> "$FAKE_CALLS"
    case "$1" in -d) exit 0 ;; esac
    echo /dev/loop99
    """)

    script.("lsblk", """
    printf '/dev/loop99 \\n/dev/loop99p2 ESP\\n/dev/loop99p3 root\\n'
    """)

    script.("btrfstune", """
    printf 'btrfstune %s\\n' "$*" >> "$FAKE_CALLS"
    """)

    # The mounted image: what `nix/worker-image.nix` puts in its root.
    script.("mount", """
    printf 'mount %s\\n' "$*" >> "$FAKE_CALLS"
    mnt=${@: -1}
    echo "$FAKE_TOP" > "$mnt/forge-system"
    : > "$mnt/nix-path-registration"
    mkdir -p "$mnt$FAKE_TOP"
    # As in a NixOS toplevel, `kernel` and `initrd` are **absolute** links into the store, and the
    # files they name exist in the image and nowhere else: the running machine's store lacks them.
    mkdir -p "$mnt/nix/store/kkkk-linux" "$mnt/nix/store/iiii-initrd"
    echo kernel > "$mnt/nix/store/kkkk-linux/bzImage"
    echo initrd > "$mnt/nix/store/iiii-initrd/initrd"
    ln -s /nix/store/kkkk-linux/bzImage "$mnt$FAKE_TOP/kernel"
    ln -s /nix/store/iiii-initrd/initrd "$mnt$FAKE_TOP/initrd"
    """)

    script.("umount", """
    printf 'umount %s\\n' "$*" >> "$FAKE_CALLS"
    """)

    # Whether the boot partition is mounted: it is, unless a test says otherwise.
    script.("mountpoint", """
    [ -z "${FAKE_ESP_UNMOUNTED:-}" ]
    """)

    script.("systemctl", """
    printf 'systemctl %s\\n' "$*" >> "$FAKE_CALLS"
    """)
  end

  # An image: its gz, served by digest, and what the platform would be told of it.
  defp image(context, opts \\ []) do
    raw = Keyword.get(opts, :raw, "RAW DISK IMAGE " <> String.duplicate("x", 5000))
    raw_path = Path.join(context.base, "image.raw.src")
    File.write!(raw_path, raw)
    {_out, 0} = System.cmd("gzip", ["-kn", "-f", raw_path])
    gz = raw_path <> ".gz"

    gz_digest = sha(File.read!(gz))
    served = Path.join(context.base, "served")
    File.mkdir_p!(served)
    File.write!(Path.join(served, "token"), ~s({"token":"t"}))
    File.cp!(gz, Path.join(served, "blob-#{gz_digest}"))

    %{
      served: served,
      digest: "sha256:#{Keyword.get(opts, :digest, gz_digest)}",
      raw_sha: Keyword.get(opts, :raw_sha, sha(raw)),
      raw_size: Keyword.get(opts, :raw_size, byte_size(raw)),
      gz: Path.join(served, "blob-#{gz_digest}")
    }
  end

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp env(context, extra) do
    top = "/nix/store/#{@new_hash}-nixos-system-new"
    new = Path.join([context.base, top])
    unless File.dir?(new), do: system(context.base, @new_hash, "new")

    [
      {"PATH", Path.join(context.dirs["bin"], "") <> ":" <> System.get_env("PATH")},
      {"FORGE_UPDATE_DIR", context.dirs["update"]},
      {"FORGE_UPDATE_REPOSITORY", @repository},
      {"FORGE_UPDATE_ESP", context.dirs["esp"]},
      {"FORGE_UPDATE_GCROOTS", context.dirs["gcroots"]},
      {"FORGE_UPDATE_MENU", @menu},
      {"FORGE_UPDATE_RUNNING", context.run_link},
      {"FORGE_UPDATE_LAYOUT", context.layout},
      {"FORGE_UPDATE_PREFIX", Path.join(context.base, "")},
      {"FAKE_CALLS", context.calls},
      {"FAKE_DIR", Path.join(context.base, "served")},
      {"FAKE_TOP", top}
    ] ++ extra
  end

  defp run(context, args, extra \\ []) do
    {out, status} =
      System.cmd("bash", [@script | args], env: env(context, extra), stderr_to_stdout: true)

    {status, out |> String.split("\n", trim: true) |> List.last(), out}
  end

  defp calls(context) do
    case File.read(context.calls) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp fetch(context, image, opts \\ []) do
    run(context, [
      "fetch",
      Keyword.get(opts, :repository, @repository),
      "0.23.0",
      image.digest,
      image.raw_sha,
      to_string(image.raw_size)
    ])
  end

  defp leftovers(context),
    do: context.dirs["update"] |> File.ls!() |> Enum.filter(&(&1 =~ ~r/^image\./))

  describe "fetch" do
    test "downloads, checks and unpacks an image, and keeps nothing but the raw disk",
         context do
      image = image(context)
      assert {0, last, _out} = fetch(context, image)
      assert last =~ "downloaded and checked"
      assert leftovers(context) == ["image.raw"]
      assert File.read!(Path.join(context.dirs["update"], "image.raw")) =~ "RAW DISK IMAGE"
      assert Enum.any?(calls(context), &(&1 =~ "--proto =https"))
      refute Enum.any?(calls(context), &(&1 =~ ~r/authorization: bearer [^t]/i))
    end

    test "keeps the directory to root", context do
      image = image(context)
      assert {0, _last, _out} = fetch(context, image)
      assert File.stat!(context.dirs["update"]).mode |> Bitwise.band(0o777) == 0o700
    end

    test "refuses any repository but the one in its image, and downloads nothing", context do
      image = image(context)

      assert {1, last, _out} =
               fetch(context, image, repository: "ghcr.io/evil/forge-worker-image")

      assert last =~ "forge-update: repository: the platform named ghcr.io/evil"
      assert calls(context) == []
    end

    test "refuses a download that is not the digest the platform named, and leaves nothing",
         context do
      image = image(context, digest: String.duplicate("0", 64))
      File.cp!(image.gz, Path.join(context.base, "served/blob-" <> String.duplicate("0", 64)))

      File.write!(
        Path.join(context.base, "served/blob-" <> String.duplicate("0", 64)),
        "something else"
      )

      assert {1, last, _out} = fetch(context, image)
      assert last =~ "forge-update: checksum:"
      assert leftovers(context) == []
    end

    test "refuses a disk whose checksum or size is not the one named", context do
      assert {1, last, _out} = fetch(context, image(context, raw_sha: String.duplicate("1", 64)))
      assert last =~ "forge-update: checksum:"
      assert leftovers(context) == []

      assert {1, last, _out} = fetch(context, image(context, raw_size: 7))
      assert last =~ "forge-update: checksum:"
      assert leftovers(context) == []
    end

    test "says a failed download failed, and where", context do
      image = image(context)
      File.rm!(image.gz)
      assert {1, last, _out} = fetch(context, image)
      assert last =~ "forge-update: download:"
    end

    test "refuses an image that names no repository, with nothing downloaded", context do
      assert {1, last, _out} =
               run(context, ["fetch", @repository, "0.23.0", "x", "x", "1"], [
                 {"FORGE_UPDATE_REPOSITORY", ""}
               ])

      assert last =~ "forge-update: repository: this machine's image names no repository"
      assert calls(context) == []
    end

    test "refuses when the boot partition is not mounted, before it downloads anything",
         context do
      assert {1, last, _out} =
               run(context, ["fetch", @repository, "0.23.0", "x", "x", "1"], [
                 {"FAKE_ESP_UNMOUNTED", "1"}
               ])

      assert last =~ "forge-update: esp: the boot partition is not mounted at"
      assert calls(context) == []
    end

    test "refuses on the old layout before it downloads anything", context do
      File.rm!(context.layout)
      assert {1, last, _out} = fetch(context, image(context))
      assert last =~ "forge-update: layout: its boot partition holds one system"
      assert calls(context) == []
    end

    test "refuses a disk size a release cannot have, with nothing downloaded", context do
      image = image(context)

      assert {1, last, _out} =
               run(context, [
                 "fetch",
                 @repository,
                 "0.23.0",
                 image.digest,
                 image.raw_sha,
                 "34359738369"
               ])

      assert last =~ "forge-update: bad_image: the size is 34359738369"
      assert calls(context) == []
    end

    test "refuses each value that is not what a release has, before anything is downloaded",
         context do
      image = image(context)

      good = [
        "fetch",
        @repository,
        "0.23.0",
        image.digest,
        image.raw_sha,
        to_string(image.raw_size)
      ]

      for {index, bad} <- [
            {2, "0.23.0 ; reboot"},
            {2, "../../x"},
            {3, "sha256:" <> String.duplicate("A", 64)},
            {3, image.digest <> "0"},
            {4, String.upcase(image.raw_sha)},
            {4, "../" <> String.slice(image.raw_sha, 3..-1//1)},
            {5, "0x10"}
          ] do
        assert {1, last, _out} = run(context, List.replace_at(good, index, bad))
        assert last =~ "forge-update: bad_image:", "#{index}: #{bad}"
      end

      assert calls(context) == []
      assert {0, _last, _out} = run(context, good)
    end

    test "refuses values that are not what a release has", context do
      assert {1, last, _out} =
               run(context, ["fetch", @repository, "0.23.0", "sha256:short", "x", "1"])

      assert last =~ "forge-update: bad_image:"
      assert calls(context) == []
    end
  end

  describe "space" do
    test "collects the Nix store once when it is short, and fails with both figures if that is not enough",
         context do
      assert {1, last, _out} =
               run(context, ["space", "1000"], [
                 {"FAKE_AVAILABLE", "100"},
                 {"FORGE_UPDATE_MIN_FREE", "0"}
               ])

      assert last =~
               "forge-update: space: not enough room: 100 bytes free after collecting the Nix store, 3000 needed"

      assert Enum.count(calls(context), &(&1 =~ "--gc")) == 1
    end

    test "refuses a size no release's disk has, before it collects anything", context do
      for size <- ["34359738369", "9223372036854775807", "99999999999999999999", "0", "-1", "1e3"] do
        assert {1, last, _out} = run(context, ["space", size], [{"FAKE_AVAILABLE", "100"}])
        assert last =~ "forge-update: bad_image:", size
      end

      assert calls(context) == []
    end

    test "does not collect anything when there is room", context do
      assert {0, _last, _out} = run(context, ["space", "1000"], [{"FORGE_UPDATE_MIN_FREE", "0"}])
      assert calls(context) == []
    end
  end

  describe "install, arm, keep" do
    test "stages the new system beside the running one and does not touch the running one",
         context do
      running_entry = Path.join(context.dirs["esp"], "loader/entries/forge-#{@old_hash}.conf")
      before = File.read!(running_entry)
      menu_before = File.read!(Path.join(context.dirs["esp"], "limine/limine.conf"))

      assert {0, last, _out} = install(context)
      assert last =~ "installed"

      assert File.read!(running_entry) == before
      assert File.read!(Path.join(context.dirs["esp"], "limine/limine.conf")) == menu_before

      assert File.read!(Path.join(context.dirs["esp"], "forge/#{@new_hash}/kernel")) ==
               "kernel of new"

      # Staged is not armed: no entry names it yet, so a reboot now would still boot the old one.
      assert File.ls!(Path.join(context.dirs["esp"], "loader/entries")) == [
               "forge-#{@old_hash}.conf"
             ]

      assert File.read_link!(Path.join(context.dirs["gcroots"], "next")) =~ @new_hash
      refute File.exists?(Path.join(context.dirs["update"], "image.raw"))

      assert Enum.any?(calls(context), &(&1 =~ "btrfstune -m /dev/loop99p3"))
      assert Enum.any?(calls(context), &(&1 =~ ~r/mount -o nosuid,nodev,noexec/))
      assert Enum.any?(calls(context), &(&1 =~ "umount"))
      assert Enum.any?(calls(context), &(&1 =~ "losetup -d"))
    end

    test "removes the system before the running one and the fallback, so the boot partition holds three only while one is being installed",
         context do
      ancient = String.duplicate("c", 32)
      kept = String.duplicate("d", 32)

      for hash <- [ancient, kept] do
        top = system(context.base, hash, "x")
        {_out, 0} = System.cmd("bash", [@menu, context.dirs["esp"], "stage", hash, top])
        {_out, 0} = System.cmd("bash", [@menu, context.dirs["esp"], "enable", hash])
      end

      # The fallback is the one the roots name; the other is the system before it.
      File.ln_s!(
        Path.join([context.base, "nix", "store", "#{kept}-nixos-system-x"]),
        Path.join(context.dirs["gcroots"], "fallback")
      )

      assert {0, _last, _out} = install(context)

      assert File.ls!(Path.join(context.dirs["esp"], "forge")) |> Enum.sort() ==
               Enum.sort([@old_hash, kept, @new_hash])
    end

    test "keeps the fallback's boot files even when the store path its root names is not there",
         context do
      # The root is a link into the store, which a machine keeps; here the path is not on disk, and
      # a test of `-e` would see no fallback at all and prune it.
      fallback_id = String.duplicate("c", 32)
      File.mkdir_p!(Path.join(context.dirs["esp"], "forge/#{fallback_id}"))
      File.write!(Path.join(context.dirs["esp"], "forge/#{fallback_id}/kernel"), "kernel")

      File.ln_s!(
        "/nix/store/#{fallback_id}-nixos-system-fallback",
        Path.join(context.dirs["gcroots"], "fallback")
      )

      assert {0, _last, _out} = install(context)
      assert File.exists?(Path.join(context.dirs["esp"], "forge/#{fallback_id}/kernel"))
    end

    test "sizes the new kernel and initrd inside the image, where their absolute links point",
         context do
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")
      # The stand-in's kernel and initrd are 7 and 7 bytes; with a megabyte of margin, one byte
      # short of that is refused and one more is not. The running machine's store holds neither.
      need = 7 + 7 + 1_048_576

      assert {1, last, _out} =
               run(context, ["install", @build], [
                 {"FAKE_WORKER_HASH", @build},
                 {"FAKE_AVAILABLE", to_string(need - 1)}
               ])

      assert last =~ "forge-update: space: not enough room on the boot partition"
      assert last =~ "#{need - 1} bytes free, #{need} needed"

      # Installing cleans the downloaded disk up whether or not it got that far, and the stand-in
      # `mount` leaves its files where a real unmount would show an empty directory.
      File.rm_rf!(Path.join(context.dirs["update"], "mnt"))
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")

      assert {0, _last, _out} =
               run(context, ["install", @build], [
                 {"FAKE_WORKER_HASH", @build},
                 {"FAKE_AVAILABLE", to_string(need)}
               ])
    end

    test "refuses when the boot partition has no room for the new system's kernel", context do
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")

      assert {1, last, _out} =
               run(context, ["install", @build], [
                 {"FAKE_WORKER_HASH", @build},
                 {"FAKE_AVAILABLE", "100"}
               ])

      assert last =~ "forge-update: space: not enough room on the boot partition: 100 bytes free"
      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))
    end

    test "refuses an image whose worker is not the build the platform named", context do
      assert {1, last, _out} = install(context, "othrothrothr")

      assert last =~
               "forge-update: bad_image: the image holds worker build #{@build}, not the othrothrothr"

      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))
      refute Enum.any?(calls(context), &(&1 =~ "nix copy"))
      # The mount and the loop device go whatever happened.
      assert Enum.any?(calls(context), &(&1 =~ "umount"))
    end

    test "refuses a build that is not twelve lowercase letters and digits, before any mount",
         context do
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")

      for build <- ["short", "WWWWWWWWWWWW", "www/wwwwwwww", "wwwwwwwwwwwww"] do
        assert {1, last, _out} = run(context, ["install", build], [{"FAKE_WORKER_HASH", @build}])
        assert last =~ "forge-update: bad_image: the build is not what a release has", build
      end

      refute Enum.any?(calls(context), &(&1 =~ ~r/^(losetup|mount)/))
    end

    test "refuses an image whose system holds two workers, even one of them the build", context do
      assert {1, last, _out} = install(context, @build, [{"FAKE_TWO_WORKERS", "1"}])
      assert last =~ "forge-update: bad_image: the image's system holds no single forge worker"
      refute Enum.any?(calls(context), &(&1 =~ "nix copy"))
    end

    test "refuses an image that holds no worker, or two", context do
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")
      # The stand-in's closure has exactly one; an empty answer is none.
      assert {1, last, _out} =
               run(context, ["install", @build], [{"FAKE_WORKER_HASH", "NOT-A-HASH"}])

      assert last =~ "forge-update: bad_image:"
    end

    test "arms a trial entry that sorts first, and says what to fall back to", context do
      assert {0, _last, _out} = install(context)
      assert {0, _last, _out} = run(context, ["arm", @build])

      entries = File.ls!(Path.join(context.dirs["esp"], "loader/entries"))
      assert "forge-#{@new_hash}+1.conf" in entries
      assert "forge-#{@old_hash}.conf" in entries
      limine = File.read!(Path.join(context.dirs["esp"], "limine/limine.conf"))

      assert limine |> String.split("/forge-worker ") |> Enum.at(1) =~
               String.slice(@new_hash, 0, 12)

      # Strictly higher, not equal: on a tie the old system may still be the one that boots first.
      version = fn name ->
        [_all, v] =
          Regex.run(
            ~r/^version (\d+)$/m,
            File.read!(Path.join(context.dirs["esp"], "loader/entries/#{name}.conf"))
          )

        String.to_integer(v)
      end

      assert version.("forge-#{@new_hash}+1") > version.("forge-#{@old_hash}")

      trial = File.read!(Path.join(context.dirs["update"], "trial"))
      assert trial =~ "system=/nix/store/#{@new_hash}-nixos-system-new"
      assert trial =~ "previous_id=#{@old_hash}"
      refute File.exists?(Path.join(context.dirs["update"], "staged"))
    end

    test "arm refuses a system that is not the one installed, and when the running one has no entry to go back to",
         context do
      assert {0, _last, _out} = install(context)
      assert {1, last, _out} = run(context, ["arm", "othrothrothr"])
      assert last =~ "forge-update: install: the installed system is build #{@build}"

      File.rm_rf!(Path.join(context.dirs["esp"], "forge/#{@old_hash}"))
      assert {1, last, _out} = run(context, ["arm", @build])
      assert last =~ "no boot entry to fall back to"
    end

    test "keeps it only when it is the system running, and then moves the roots and drops the system before",
         context do
      assert {0, _last, _out} = install(context)
      assert {0, _last, _out} = run(context, ["arm", @build])

      # Still on the old system: the machine rebooted into nothing new.
      assert {1, last, _out} = run(context, ["keep"])
      assert last =~ "the running system is not the one on trial"

      assert "forge-#{@new_hash}+1.conf" in File.ls!(
               Path.join(context.dirs["esp"], "loader/entries")
             )

      # An older fallback that the new one pushes out.
      ancient = String.duplicate("c", 32)
      File.mkdir_p!(Path.join(context.dirs["esp"], "forge/#{ancient}"))
      File.write!(Path.join(context.dirs["esp"], "forge/#{ancient}/kernel"), "old")

      File.rm!(context.run_link)

      File.ln_s!(
        Path.join([context.base, "nix", "store", "#{@new_hash}-nixos-system-new"]),
        context.run_link
      )

      assert {0, last, _out} = run(context, ["keep"])
      assert last =~ "kept"

      assert File.ls!(Path.join(context.dirs["esp"], "loader/entries")) |> Enum.sort() ==
               ["forge-#{@old_hash}.conf", "forge-#{@new_hash}.conf"]

      assert File.ls!(Path.join(context.dirs["esp"], "forge")) |> Enum.sort() == [
               @old_hash,
               @new_hash
             ]

      assert File.read_link!(Path.join(context.dirs["gcroots"], "current")) =~ @new_hash
      assert File.read_link!(Path.join(context.dirs["gcroots"], "fallback")) =~ @old_hash
      refute File.exists?(Path.join(context.dirs["gcroots"], "next"))
      refute File.exists?(Path.join(context.dirs["update"], "trial"))
    end

    # What systemd-boot does to a trial's entry when it boots it: `+1` becomes `+0-1`.
    defp boot_counted(context) do
      entries = Path.join(context.dirs["esp"], "loader/entries")

      File.rename!(
        Path.join(entries, "forge-#{@new_hash}+1.conf"),
        Path.join(entries, "forge-#{@new_hash}+0-1.conf")
      )
    end

    test "keeps a system whose entry systemd-boot has already counted, leaving no counter",
         context do
      armed(context)
      boot_counted(context)
      boot_new(context)

      assert {0, _last, _out} = run(context, ["keep"])

      assert File.ls!(Path.join(context.dirs["esp"], "loader/entries")) |> Enum.sort() ==
               ["forge-#{@old_hash}.conf", "forge-#{@new_hash}.conf"]
    end

    test "refuses to install or arm when the boot partition is not mounted, writing nothing",
         context do
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")
      unmounted = [{"FAKE_ESP_UNMOUNTED", "1"}, {"FAKE_WORKER_HASH", @build}]

      assert {1, last, _out} = run(context, ["install", @build], unmounted)
      assert last =~ "forge-update: esp:"
      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))
      refute Enum.any?(calls(context), &(&1 =~ ~r/^(losetup|mount|nix)/))

      assert {0, _last, _out} = install(context)
      assert {1, last, _out} = run(context, ["arm", @build], unmounted)
      assert last =~ "forge-update: esp:"
      refute File.exists?(Path.join(context.dirs["update"], "trial"))
    end

    test "refuses on the old layout without touching the boot partition", context do
      File.rm!(context.layout)
      File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")
      assert {1, last, _out} = run(context, ["install", @build])
      assert last =~ "forge-update: layout:"
      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))
    end
  end

  describe "fallback" do
    defp armed(context) do
      assert {0, _last, _out} = install(context)
      assert {0, _last, _out} = run(context, ["arm", @build])
    end

    defp boot_new(context) do
      File.rm!(context.run_link)

      File.ln_s!(
        Path.join([context.base, "nix", "store", "#{@new_hash}-nixos-system-new"]),
        context.run_link
      )
    end

    test "on the new system takes the entry out of both menus, says why, and reboots", context do
      armed(context)
      boot_new(context)

      assert {0, _last, _out} = run(context, ["fallback", "not accepted within 15 minutes"])

      assert File.ls!(Path.join(context.dirs["esp"], "loader/entries")) == [
               "forge-#{@old_hash}.conf"
             ]

      refute File.read!(Path.join(context.dirs["esp"], "limine/limine.conf")) =~
               String.slice(@new_hash, 0, 12)

      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))

      assert File.read!(Path.join(context.dirs["update"], "result")) =~
               "reason=not accepted within 15 minutes"

      assert "systemctl reboot" in calls(context)
    end

    test "takes an entry systemd-boot has counted out of the menu as well", context do
      armed(context)
      boot_counted(context)

      assert {0, _last, _out} = run(context, ["fallback", "the new system did not come up"])

      assert File.ls!(Path.join(context.dirs["esp"], "loader/entries")) == [
               "forge-#{@old_hash}.conf"
             ]
    end

    test "of the system that is also the fallback drops the fallback root with its boot files",
         context do
      # Updating down to the release that is the fallback: the same id, staged over its own files.
      fallback = Path.join(context.dirs["gcroots"], "fallback")
      File.ln_s!("/nix/store/#{@new_hash}-nixos-system-new", fallback)
      armed(context)
      boot_new(context)

      assert {0, _last, _out} = run(context, ["fallback", "not accepted"])

      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))
      assert {:error, :enoent} = File.read_link(fallback)
    end

    test "of a system that is not the fallback leaves the fallback root alone", context do
      fallback = Path.join(context.dirs["gcroots"], "fallback")
      File.ln_s!("/nix/store/#{String.duplicate("c", 32)}-nixos-system-older", fallback)
      armed(context)
      boot_new(context)

      assert {0, _last, _out} = run(context, ["fallback", "not accepted"])
      assert {:ok, _target} = File.read_link(fallback)
    end

    test "on the old system, where boot counting already went back, only says so", context do
      armed(context)

      assert {0, _last, _out} = run(context, ["fallback", "the new system did not come up"])
      assert File.read!(Path.join(context.dirs["update"], "result")) =~ "outcome=fell_back"
      refute "systemctl reboot" in calls(context)
      refute File.exists?(Path.join(context.dirs["update"], "trial"))
    end

    test "with no trial is nothing at all, which is what the timer finds after a keep", context do
      assert {0, _last, _out} = run(context, ["fallback"])
      assert calls(context) == []
      refute File.exists?(Path.join(context.dirs["update"], "result"))
    end
  end

  describe "the boot menu's own refusals" do
    defp menu(context, args),
      do: System.cmd("bash", [@menu, context.dirs["esp"] | args], stderr_to_stdout: true)

    test "takes no id that could name a path, so nothing is staged or removed outside the ESP",
         context do
      top = system(context.base, @new_hash, "new")
      # `../outside` from `esp/forge/` is `esp/outside`: where a path-shaped id would land.
      outside = Path.join(context.dirs["esp"], "outside")
      File.mkdir_p!(outside)

      for id <- ["../outside", "a/b", "short", "UPPERCASEUPPERCASE", String.duplicate("a", 65)] do
        assert {out, 1} = menu(context, ["stage", id, top]), id
        assert out =~ "not a system id", id
        assert {_out, 1} = menu(context, ["remove", id]), id
        assert {_out, 1} = menu(context, ["enable", id]), id
      end

      assert File.dir?(outside)
      assert File.ls!(Path.join(context.dirs["esp"], "forge")) == [@old_hash]
    end

    test "stages only what is a system: it must say how to boot", context do
      top = system(context.base, @new_hash, "new")
      File.rm!(Path.join(top, "kernel-params"))

      assert {out, 1} = menu(context, ["stage", @new_hash, top])
      assert out =~ "no kernel-params"
      refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}/kernel"))
    end
  end

  test "discard takes the staged system back off the boot partition and the roots", context do
    assert {0, _last, _out} = install(context)
    assert {0, _last, _out} = run(context, ["discard"])
    refute File.exists?(Path.join(context.dirs["esp"], "forge/#{@new_hash}"))
    refute File.exists?(Path.join(context.dirs["gcroots"], "next"))

    assert File.ls!(Path.join(context.dirs["esp"], "loader/entries")) == [
             "forge-#{@old_hash}.conf"
           ]
  end

  test "discard of the system that is also the fallback drops the fallback root too", context do
    fallback = Path.join(context.dirs["gcroots"], "fallback")
    File.ln_s!("/nix/store/#{@new_hash}-nixos-system-new", fallback)
    assert {0, _last, _out} = install(context)
    assert {0, _last, _out} = run(context, ["discard"])
    assert {:error, :enoent} = File.read_link(fallback)
  end

  test "an unknown command is refused", context do
    assert {1, last, _out} = run(context, ["format-everything"])
    assert last =~ "forge-update: usage:"
  end

  defp install(context, build \\ @build, extra \\ []) do
    File.write!(Path.join(context.dirs["update"], "image.raw"), "disk")
    run(context, ["install", build], [{"FAKE_WORKER_HASH", @build} | extra])
  end
end
