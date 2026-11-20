defmodule ForgeWorker.Job.WorkspaceLfsTest do
  @moduledoc """
  A worker's checkout holds the real files of a repository that keeps some in Git LFS, and a run's
  LFS files reach the platform with its push (`docs/design/git-hosting.md` § The job's own git).

  The origin is a local bare repository, and its `lfs/objects` is the LFS server: git-lfs serves a
  local remote itself, from that directory, with no HTTP. What a real platform's endpoint adds is
  the platform suite's (`ForgeWeb.GitLfsHttpTest`); what neither has is a worker against a real
  platform over HTTP, which is named in the note's *Not verified here*.

  Not async: `GIT_LFS_SKIP_SMUDGE` is the worker's own environment, which every test shares.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Checkout
  alias ForgeWorker.Job.Workspace

  @direct {ForgeWorker.Slice.Direct, %{kind: :direct}}
  @pointer_head "version https://git-lfs.github.com/spec/v1"

  setup do
    origin = Path.join(tmp_dir("origin"), "project.git")
    seed = tmp_dir("seed")
    git!(nil, ["init", "--bare", "--quiet", origin])
    git!(nil, ["clone", "--quiet", origin, seed])

    for {k, v} <- [{"user.name", "seed"}, {"user.email", "seed@forge"}],
        do: git!(seed, ["config", k, v])

    git!(seed, ["lfs", "install", "--local"])
    File.write!(Path.join(seed, ".gitattributes"), "*.bin filter=lfs diff=lfs merge=lfs -text\n")
    File.mkdir_p!(Path.join(seed, "audio"))
    File.write!(Path.join(seed, "audio/boom.bin"), "BOOM version one")
    git!(seed, ["add", "-A"])
    git!(seed, ["commit", "--quiet", "-m", "one"])
    first = git!(seed, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(seed, "audio/boom.bin"), "BOOM version two")
    git!(seed, ["commit", "--quiet", "-am", "two"])
    git!(seed, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])

    %{origin: origin, seed: seed, root: tmp_dir("root"), first: first}
  end

  defp assignment(origin, opts \\ []) do
    %{
      "job_id" => uuid(),
      "spec" => %{"state" => "planning", "attempt" => 1},
      "resume_session" => nil,
      "git" => %{
        "url" => origin,
        "branch" => "ticket/1",
        "base" => nil,
        "token" => Keyword.get(opts, :token)
      }
    }
  end

  defp git!(dir, args, env \\ []) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, status} = System.cmd("git", args, stderr_to_stdout: true, env: env)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  defp objects(origin), do: Path.wildcard(Path.join(origin, "lfs/objects/*/*/*"))

  test "a cold clone holds the real bytes, not a pointer", c do
    assert {:ok, dir} = Workspace.prepare(assignment(c.origin), c.root, @direct)

    assert File.read!(Path.join(dir, "audio/boom.bin")) == "BOOM version two"
  end

  test "a snapshot of the ticket's volume holds them too, and downloads only what it lacks", c do
    first = assignment(c.origin)
    {:ok, dir} = Workspace.prepare(first, c.root, @direct)
    :ok = Workspace.promote(first, c.root, dir)

    # Origin's copy is gone, so a download would fail: the template's own is what is read.
    Enum.each(objects(c.origin), &File.rm!/1)

    assert {:ok, again} = Workspace.prepare(assignment(c.origin), c.root, @direct)
    assert File.read!(Path.join(again, "audio/boom.bin")) == "BOOM version two"
  end

  test "a command's checkout at an older commit holds that commit's bytes", c do
    {:ok, dir} = Workspace.prepare(assignment(c.origin), c.root, @direct)
    git!(dir, ["fetch", "--quiet", "origin", c.first])

    assert :ok = Checkout.detach(dir, c.first, url: c.origin, as: &Function.identity({&1, &2}))
    assert File.read!(Path.join(dir, "audio/boom.bin")) == "BOOM version one"
  end

  test "a download that fails fails the checkout, and says so", c do
    Enum.each(objects(c.origin), &File.rm!/1)

    assert {:error, {code, out}} = Workspace.prepare(assignment(c.origin), c.root, @direct)
    assert code != 0
    assert out =~ "smudge filter lfs failed"
    # And the failed clone leaves no tree behind to be taken for a run's own.
    refute File.dir?(Workspace.dir(assignment(c.origin), c.root))
  end

  describe "a .lfsconfig in the repository" do
    setup c do
      File.write!(Path.join(c.seed, ".lfsconfig"), """
      [lfs]
      \turl = file:///nowhere/at/all
      \tpushurl = file:///nowhere/at/all
      \tskipdownloaderrors = true
      \tfetchexclude = *
      """)

      git!(c.seed, ["add", "-A"])
      git!(c.seed, ["commit", "--quiet", "-m", "a config that says otherwise"])
      git!(c.seed, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])
      :ok
    end

    test "changes nothing about what is downloaded", c do
      assert {:ok, dir} = Workspace.prepare(assignment(c.origin), c.root, @direct)
      assert File.read!(Path.join(dir, "audio/boom.bin")) == "BOOM version two"
    end

    test "cannot make a failed download pass", c do
      Enum.each(objects(c.origin), &File.rm!/1)
      assert {:error, {_code, out}} = Workspace.prepare(assignment(c.origin), c.root, @direct)
      assert out =~ "smudge filter lfs failed"
    end

    test "cannot move an upload anywhere else", c do
      job = assignment(c.origin)
      {:ok, dir} = Workspace.prepare(job, c.root, @direct)
      File.write!(Path.join(dir, "audio/new.bin"), "NEW BYTES")

      assert {:ok, _head} = Workspace.commit_and_push(job, dir, "run: attempt 1", @direct)
      assert Enum.any?(objects(c.origin), &(File.read!(&1) == "NEW BYTES"))
    end
  end

  test "the squash commits a new LFS file as a pointer, and the push puts its object on the origin",
       c do
    job = assignment(c.origin)
    {:ok, dir} = Workspace.prepare(job, c.root, @direct)
    File.write!(Path.join(dir, "audio/new.bin"), "NEW BYTES")
    # The worker's own push does not depend on a hook the agent may have turned off (removing the
    # file is not enough: git-lfs puts a missing hook back the next time it runs).
    git!(dir, ["config", "core.hooksPath", "/nonexistent"])

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "run: attempt 1", @direct)

    assert git!(c.origin, ["show", head <> ":audio/new.bin"]) =~ @pointer_head
    assert Enum.any?(objects(c.origin), &(File.read!(&1) == "NEW BYTES"))
  end

  test "so does a plain git push, as the agent would run it", c do
    {:ok, dir} = Workspace.prepare(assignment(c.origin), c.root, @direct)
    File.write!(Path.join(dir, "audio/agent.bin"), "AGENT BYTES")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "the agent's own"])

    git!(dir, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])

    assert Enum.any?(objects(c.origin), &(File.read!(&1) == "AGENT BYTES"))
  end

  test "a template from before is put right on its next use", c do
    job = assignment(c.origin)
    {:ok, dir} = Workspace.prepare(job, c.root, @direct)
    # What an older worker left: no pins, no helper, nothing but what the clone wrote.
    for key <- ["lfs.url", "lfs.pushurl", "lfs.fetchexclude", "lfs.skipdownloaderrors"] do
      System.cmd("git", ["-C", dir, "config", "--local", "--unset-all", key])
    end

    git!(dir, ["config", "--local", "lfs.fetchexclude", "*"])

    assert {:ok, ^dir} = Workspace.prepare(job, c.root, @direct)

    assert git!(dir, ["config", "--local", "--get", "lfs.url"]) |> String.trim() ==
             "file://" <> c.origin

    assert git!(dir, ["config", "--local", "--get", "lfs.pushurl"]) |> String.trim() ==
             "file://" <> c.origin

    assert git!(dir, ["config", "--local", "--get-all", "lfs.fetchexclude"]) |> String.trim() ==
             ""
  end

  test "GIT_LFS_SKIP_SMUDGE in the worker's environment is ignored", c do
    System.put_env("GIT_LFS_SKIP_SMUDGE", "1")
    on_exit(fn -> System.delete_env("GIT_LFS_SKIP_SMUDGE") end)

    assert {:ok, dir} = Workspace.prepare(assignment(c.origin), c.root, @direct)
    assert File.read!(Path.join(dir, "audio/boom.bin")) == "BOOM version two"
  end

  describe "the endpoint git-lfs derives" do
    test "from an http(s) URL, with and without .git, and from a local path" do
      assert Checkout.endpoint("http://h:4000/git/p.git") == "http://h:4000/git/p.git/info/lfs"
      assert Checkout.endpoint("https://h/git/p") == "https://h/git/p.git/info/lfs"
      assert Checkout.endpoint("https://h/git/p.git/") == "https://h/git/p.git/info/lfs"
      assert Checkout.endpoint("/var/repos/p.git") == "file:///var/repos/p.git"

      assert Checkout.endpoint("http://[fd00::1]:4000/git/p.git") ==
               "http://[fd00::1]:4000/git/p.git/info/lfs"

      assert Checkout.endpoint("http://forge_platform:4000/git/p") ==
               "http://forge_platform:4000/git/p.git/info/lfs"

      assert Checkout.endpoint("git@h:p.git") == nil
      assert Checkout.endpoint(nil) == nil
      assert Checkout.endpoint("http://a;rm -rf/x") == nil
    end
  end

  describe "the credential helper" do
    @url "http://platform.example:4000/git/p.git"

    # What git asks a helper, as `git credential fill` does, with the helper handed in as an
    # argument so that nothing of it is read by this shell.
    defp fill(helper, input, dir) do
      git!(dir, ["init", "--quiet"])
      file = Path.join(dir, "request")
      File.write!(file, input <> "\n\n")

      System.cmd(
        "sh",
        [
          "-c",
          ~s(git -c credential.helper= -c "credential.helper=$1" credential fill < "$0"),
          file,
          helper
        ],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"FORGE_GIT_TOKEN", "the-token"}, {"GIT_TERMINAL_PROMPT", "0"}]
      )
    end

    test "answers the platform's host and no other" do
      helper = Checkout.helper(@url)
      dir = tmp_dir("helper")

      assert {out, 0} = fill(helper, "protocol=http\nhost=platform.example:4000", dir)
      assert out =~ "password=the-token"

      for input <- [
            "protocol=http\nhost=evil.example:4000",
            "protocol=http\nhost=platform.example",
            "protocol=http\nhost=platform.example:40001",
            "protocol=https\nhost=platform.example:4000"
          ] do
        assert {out, code} = fill(helper, input, dir)
        assert code != 0
        refute out =~ "the-token"
      end
    end

    test "answers an IPv6 platform and a name with an underscore, and still only them" do
      dir = tmp_dir("helper-hosts")

      for {url, host} <- [
            {"http://[fd00::1]:4000/git/p.git", "[fd00::1]:4000"},
            {"http://forge_platform:4000/git/p.git", "forge_platform:4000"}
          ] do
        helper = Checkout.helper(url)
        assert helper, url
        assert {out, 0} = fill(helper, "protocol=http\nhost=" <> host, dir)
        assert out =~ "password=the-token"

        # A bracket is a pattern to an unquoted shell word, and the helper runs in the checkout: a
        # file there named for a host the pattern matches would make that host the platform's.
        File.write!(Path.join(dir, "f:4000"), "")
        assert {out, code} = fill(helper, "protocol=http\nhost=f:4000", dir)
        assert code != 0
        refute out =~ "the-token"
      end
    end

    test "is none for a URL with no host a shell may be given" do
      assert Checkout.helper("/var/repos/p.git") == nil
      assert Checkout.helper("http://a b/x") == nil
      assert Checkout.helper("http://$(touch x)/x") == nil
      assert Checkout.helper(nil) == nil
    end

    test "hands a host an agent pointed git-lfs at no token" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      parent = self()

      acceptor =
        Task.async(fn -> accept_all(listener, parent, []) end)

      dir = tmp_dir("agent")
      git!(dir, ["init", "--quiet"])
      git!(dir, ["lfs", "install", "--local"])
      git!(dir, ["remote", "add", "origin", "http://127.0.0.1:#{port}/x.git"])
      git!(dir, ["config", "lfs.url", "http://127.0.0.1:#{port}/x.git/info/lfs"])
      # Configured as `Checkout` configures it, for the platform's host, which this is not.
      git!(dir, ["config", "--add", "credential.helper", Checkout.helper(@url)])

      run = fn ->
        System.cmd("git", ["-C", dir, "lfs", "locks"],
          stderr_to_stdout: true,
          env: [{"FORGE_GIT_TOKEN", "the-token"}, {"GIT_TERMINAL_PROMPT", "0"}]
        )
      end

      run.()
      send(acceptor.pid, :stop)
      seen = Task.await(acceptor)
      assert seen != []
      refute Enum.any?(seen, &(&1 =~ "authorization: Basic"))

      # The control: the same agent, a helper for *this* host, is handed the token — so the
      # absence above is the host test's doing and not a client that never asked.
      {:ok, listener2} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port2} = :inet.port(listener2)
      acceptor2 = Task.async(fn -> accept_all(listener2, parent, []) end)
      git!(dir, ["config", "lfs.url", "http://127.0.0.1:#{port2}/x.git/info/lfs"])

      git!(dir, [
        "config",
        "--replace-all",
        "credential.helper",
        Checkout.helper("http://127.0.0.1:#{port2}/x.git")
      ])

      run.()
      send(acceptor2.pid, :stop)
      assert Enum.any?(Task.await(acceptor2), &(String.downcase(&1) =~ "authorization: basic"))
    end

    test "a helper from the worker's own git config answers for no host", c do
      # A helper in the machine's global config would otherwise be asked first, for every host.
      home = tmp_dir("home")

      File.write!(Path.join(home, ".gitconfig"), """
      [credential]
      \thelper = "!f() { printf 'username=global\\\\npassword=GLOBAL-TOKEN\\\\n'; }; f"
      """)

      previous = System.get_env("HOME")
      System.put_env("HOME", home)
      on_exit(fn -> if previous, do: System.put_env("HOME", previous) end)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      acceptor = Task.async(fn -> accept_all(listener, self(), []) end)

      url = "http://127.0.0.1:#{port}/x.git"
      dir = Path.join(tmp_dir("clone-into"), "wt")

      assert {:error, _} =
               Checkout.ensure(
                 dir: dir,
                 url: url,
                 branch: "ticket/1",
                 token: "THE-TOKEN",
                 as: &{&1, &2}
               )

      send(acceptor.pid, :stop)
      seen = Task.await(acceptor)

      auth =
        for request <- seen,
            [_, b64] <- [Regex.run(~r/authorization: Basic (\S+)/i, request)],
            do: Base.decode64!(b64)

      # The platform's own helper is the one that answered; the worker's global one was reset.
      assert "forge:THE-TOKEN" in auth
      refute Enum.any?(auth, &(&1 =~ "GLOBAL-TOKEN"))
      _ = c
    end

    test "configure replaces a helper a seed or template already had", c do
      {:ok, dir} = Workspace.prepare(assignment(c.origin), c.root, @direct)
      git!(dir, ["config", "--local", "--add", "credential.helper", "!echo seed-helper"])
      url = "http://platform.example:4000/git/p.git"

      assert :ok =
               Checkout.ensure(
                 dir: dir,
                 url: url,
                 branch: "ticket/1",
                 resume: true,
                 as: &{&1, &2}
               )

      helpers =
        git!(dir, ["config", "--local", "--get-all", "credential.helper"])
        |> String.split("\n", trim: false)

      assert helpers == ["", Checkout.helper(url), ""]
    end

    defp accept_all(listener, parent, seen) do
      receive do
        :stop -> Enum.reverse(seen)
      after
        0 ->
          case :gen_tcp.accept(listener, 200) do
            {:ok, socket} ->
              request = read_request(socket, "")

              :gen_tcp.send(socket, reply(request))

              :gen_tcp.close(socket)
              accept_all(listener, parent, [request | seen])

            {:error, _timeout} ->
              accept_all(listener, parent, seen)
          end
      end
    end

    # A challenge for a request with no credential; and, so that a client handed one does not ask
    # again for ever, a plain 404 for one that sent it.
    defp reply(request) do
      if String.downcase(request) =~ "authorization: basic",
        do: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        else:
          "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end

    defp read_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} ->
          acc = acc <> data
          if String.contains?(acc, "\r\n\r\n"), do: acc, else: read_request(socket, acc)

        {:error, _reason} ->
          acc
      end
    end
  end
end
