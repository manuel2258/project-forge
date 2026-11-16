defmodule ForgeWorker.CodexUpdateTest do
  @moduledoc """
  The script `codex-update.service` runs (`nix/codex-update.sh`), against a stand-in `curl` that
  serves a tarball shaped like OpenAI's `codex-package` release (`docs/design/codex.md` § On the
  image): `bin/{codex,codex-code-mode-host,codex-exec-server}`, `codex-package.json`, `codex-path/rg`,
  no top-level directory and no `./` entry for the directory itself. **The shape was read off a real `rust-v0.169.0` package; nothing here
  fetches one.**

  Inline in the image it was the one thing in the unit no test could run, and it installed the lone
  `codex` binary, whose tool calls all failed closed for want of `codex-code-mode-host`.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../../nix/codex-update.sh", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "codex-update-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    bin = Path.join(base, "fake-bin")
    File.mkdir_p!(home)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(base) end)

    # A `curl` that serves what `FAKE_TARBALL` names; `FAKE_CURL=half` dies after 200 bytes, as a
    # connection that drops mid-download does, `FAKE_CURL=late` sends the whole of it and then fails,
    # which a pipeline reading only the last status would call success, and `FAKE_CURL=refused` serves
    # nothing.
    File.write!(Path.join(bin, "curl"), """
    #!/usr/bin/env bash
    case "${FAKE_CURL-}" in
      half) head -c 200 "$FAKE_TARBALL"; exit 18 ;;
      late) cat "$FAKE_TARBALL"; exit 18 ;;
      refused) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
      *) cat "$FAKE_TARBALL" ;;
    esac
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
    %{base: base, home: home, bin: bin, status: Path.join(base, "codex-update.json")}
  end

  # A package at `version`. `host: false` leaves the host out, as the lone asset does;
  # `host_mode:` gives it a mode, `exec_server: false` leaves that out, and `codex_body:` is what the
  # package's `codex` runs, in place of answering `--version`.
  defp package(base, version, opts \\ []) do
    dir = Path.join(base, "pkg-#{version}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "codex-path"))

    manifest =
      Keyword.get(
        opts,
        :manifest,
        ~s({"layoutVersion":1,"entrypoint":"bin/codex","execServer":"bin/codex-exec-server"})
      )

    File.write!(Path.join(dir, "codex-package.json"), manifest)

    executable(
      Path.join(dir, "bin/codex"),
      Keyword.get(opts, :codex_body, "echo 'codex-cli #{version}'")
    )

    if Keyword.get(opts, :exec_server, true),
      do: executable(Path.join(dir, "bin/codex-exec-server"), "exit 0")

    executable(Path.join(dir, "codex-path/rg"), "exit 0")

    if Keyword.get(opts, :host, true) do
      host = Path.join(dir, "bin/codex-code-mode-host")
      executable(host, "exit 0")
      if mode = opts[:host_mode], do: File.chmod!(host, mode)
    end

    tarball = dir <> ".tar.gz"
    {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", dir | File.ls!(dir)])
    tarball
  end

  defp executable(path, body) do
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o555)
  end

  defp run(ctx, tarball, env \\ []) do
    {out, 0} =
      System.cmd(
        "bash",
        [@script, ctx.home, "https://example.invalid/codex.tar.gz", ctx.status, "30", "5", "1"],
        env: [
          {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
          {"FAKE_TARBALL", tarball},
          {"HOME", ctx.base} | env
        ],
        stderr_to_stdout: true
      )

    {out, ctx.status |> File.read!() |> Jason.decode!()}
  end

  defp link(ctx), do: Path.join(ctx.home, "bin/codex")

  defp host_beside_link(ctx),
    do: ctx |> link() |> File.read_link!() |> Path.dirname() |> Path.join("codex-code-mode-host")

  defp stored(ctx), do: ctx.home |> Path.join("codex") |> File.ls!()

  test "a fresh machine ends with the host beside the codex its link resolves to", ctx do
    {_out, status} = run(ctx, package(ctx.base, "1.0.0"))

    assert status == %{"outcome" => "succeeded", "version" => "codex-cli 1.0.0"}
    assert {:ok, %{type: :symlink}} = File.lstat(link(ctx))
    assert File.regular?(host_beside_link(ctx))
    assert {"codex-cli 1.0.0\n", 0} = System.cmd(link(ctx), ["--version"])
    # And the rest the package's manifest names, which Codex goes looking for too.
    install = ctx |> link() |> File.read_link!() |> Path.dirname() |> Path.dirname()
    assert File.regular?(Path.join(install, "bin/codex-exec-server"))
    assert File.regular?(Path.join(install, "codex-path/rg"))
  end

  test "the same version again is skipped", ctx do
    tarball = package(ctx.base, "1.0.0")
    run(ctx, tarball)
    {_out, status} = run(ctx, tarball)

    assert status == %{"outcome" => "skipped", "version" => "codex-cli 1.0.0"}
    assert length(stored(ctx)) == 1
  end

  test "a newer release replaces the install and leaves nothing of the old one", ctx do
    run(ctx, package(ctx.base, "1.0.0"))
    {_out, status} = run(ctx, package(ctx.base, "1.1.0"))

    assert status == %{"outcome" => "succeeded", "version" => "codex-cli 1.1.0"}
    assert length(stored(ctx)) == 1
  end

  test "a package without the host is failed, naming it, and the old install is untouched", ctx do
    run(ctx, package(ctx.base, "1.0.0"))
    before = File.read_link!(link(ctx))

    {_out, status} = run(ctx, package(ctx.base, "2.0.0", host: false))

    assert %{"outcome" => "failed", "version" => "codex-cli 1.0.0", "error" => error} = status
    assert error =~ "bin/codex-code-mode-host"
    assert File.read_link!(link(ctx)) == before
    assert File.regular?(host_beside_link(ctx))
    assert length(stored(ctx)) == 1
  end

  # Each of these is a package `verify` must refuse, and each leaves the install the machine had
  # whole: a refusal after the swap would have lost it.
  describe "a package that is not whole is refused, and the old install is untouched" do
    setup ctx do
      run(ctx, package(ctx.base, "1.0.0"))
      %{before: File.read_link!(link(ctx))}
    end

    defp refused(ctx, before, tarball, reason) do
      {_out, status} = run(ctx, tarball)

      assert %{"outcome" => "failed", "version" => "codex-cli 1.0.0", "error" => error} = status
      assert error =~ reason
      assert File.read_link!(link(ctx)) == before
      assert {"codex-cli 1.0.0\n", 0} = System.cmd(link(ctx), ["--version"])
      assert length(stored(ctx)) == 1
    end

    test "with no exec server", ctx do
      refused(
        ctx,
        ctx.before,
        package(ctx.base, "2.0.0", exec_server: false),
        "codex-exec-server"
      )
    end

    test "with a host that is there and cannot be run", ctx do
      refused(
        ctx,
        ctx.before,
        package(ctx.base, "2.0.0", host_mode: 0o644),
        "codex-code-mode-host"
      )
    end

    test "whose codex does not answer --version", ctx do
      tarball = package(ctx.base, "2.0.0", codex_body: "exit 3")
      refused(ctx, ctx.before, tarball, "did not answer --version")
    end

    test "whose manifest names an absolute path, though it would resolve inside", ctx do
      manifest = ~s({"entrypoint":"/bin/codex","execServer":"bin/codex-exec-server"})
      refused(ctx, ctx.before, package(ctx.base, "2.0.0", manifest: manifest), "not inside")
    end
  end

  test "a link a killed run left half made does not stop the next install", ctx do
    File.mkdir_p!(Path.join(ctx.home, "bin"))
    File.ln_s!("/nowhere", link(ctx) <> ".new")

    {_out, status} = run(ctx, package(ctx.base, "1.0.0"))

    assert status == %{"outcome" => "succeeded", "version" => "codex-cli 1.0.0"}
    refute File.exists?(link(ctx) <> ".new")
  end

  test "a download that dies half way is failed and the old install is whole", ctx do
    run(ctx, package(ctx.base, "1.0.0"))
    before = File.read_link!(link(ctx))

    {_out, status} = run(ctx, package(ctx.base, "2.0.0"), [{"FAKE_CURL", "half"}])

    assert %{"outcome" => "failed", "version" => "codex-cli 1.0.0"} = status
    assert File.read_link!(link(ctx)) == before
    assert File.regular?(host_beside_link(ctx))
    assert length(stored(ctx)) == 1
  end

  test "a fetch that fails after sending a whole tarball is still failed", ctx do
    {_out, status} = run(ctx, package(ctx.base, "1.0.0"), [{"FAKE_CURL", "late"}])

    assert %{"outcome" => "failed"} = status
    refute Map.has_key?(status, "version")
    assert stored(ctx) == []
  end

  test "a fetch refused by the server is failed with what curl said", ctx do
    {_out, status} = run(ctx, package(ctx.base, "1.0.0"), [{"FAKE_CURL", "refused"}])

    assert %{"outcome" => "failed", "error" => error} = status
    assert error =~ "404"
    refute Map.has_key?(status, "version")
    assert stored(ctx) == []
  end

  test "a lone codex of the same version, as the old image left it, ends as a whole install",
       ctx do
    File.mkdir_p!(Path.join(ctx.home, "bin"))
    executable(link(ctx), "echo 'codex-cli 1.0.0'")

    {_out, status} = run(ctx, package(ctx.base, "1.0.0"))

    # Not `skipped`: the version did not change but the install did.
    assert status == %{"outcome" => "succeeded", "version" => "codex-cli 1.0.0"}
    assert {:ok, %{type: :symlink}} = File.lstat(link(ctx))
    assert File.regular?(host_beside_link(ctx))
  end

  test "a failed fetch over a lone codex reads as failed, not as installed", ctx do
    File.mkdir_p!(Path.join(ctx.home, "bin"))
    executable(link(ctx), "echo 'codex-cli 1.0.0'")

    {_out, status} = run(ctx, package(ctx.base, "1.0.0"), [{"FAKE_CURL", "refused"}])

    assert %{"outcome" => "failed"} = status
    refute Map.has_key?(status, "version")
  end

  test "directories a killed run left behind are cleared, the one in use is not", ctx do
    run(ctx, package(ctx.base, "1.0.0"))
    File.mkdir_p!(Path.join(ctx.home, "codex/codex.abandoned/bin"))
    File.mkdir_p!(Path.join(ctx.home, "codex/.hidden"))

    {_out, status} = run(ctx, package(ctx.base, "1.0.0"))

    assert status["outcome"] == "skipped"
    assert length(stored(ctx)) == 1
    assert File.regular?(host_beside_link(ctx))
  end

  test "a manifest naming a path outside the package is refused", ctx do
    manifest = ~s({"entrypoint":"../escape","execServer":"bin/codex-exec-server"})
    {_out, status} = run(ctx, package(ctx.base, "1.0.0", manifest: manifest))

    assert %{"outcome" => "failed", "error" => error} = status
    assert error =~ "not inside the package"
    assert stored(ctx) == []
  end

  test "the install's directory can be walked by the job users, not only by the worker", ctx do
    run(ctx, package(ctx.base, "1.0.0"))
    install = ctx |> link() |> File.read_link!() |> Path.dirname() |> Path.dirname()

    # `mktemp -d` makes it 0700, which would lock every job's user out of Codex.
    assert Bitwise.band(File.stat!(install).mode, 0o755) == 0o755
  end
end
