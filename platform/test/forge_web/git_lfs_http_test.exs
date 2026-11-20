defmodule ForgeWeb.GitLfsHttpTest do
  @moduledoc """
  Git LFS over the git endpoint, with a stock `git lfs` against a real socket
  (`docs/design/git-hosting.md` § Git LFS). Run `async: false`, as `GitHttpTest` is: the request
  process shares the sandbox connection.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures, only: [seeded_repo: 0]
  import Forge.LfsFixtures

  alias Forge.Git
  alias Forge.Git.{Lfs, Tokens, Url}

  setup do
    bare = seeded_repo()
    name = "lfs#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    {:ok, main} = Git.resolve(bare, "refs/heads/main")
    :ok = Git.create_branch(bare, "ticket/1", main)
    :ok = Git.create_branch(bare, "ticket/2", main)
    %{project: project, bare: bare, home: home()}
  end

  defp token!(project, opts \\ [ref: "refs/heads/ticket/1"]) do
    {:ok, secret, row} = Tokens.issue(project, [name: "t"] ++ opts)
    {secret, row}
  end

  defp push(dir, home, project, secret, refspec \\ "HEAD:refs/heads/ticket/1"),
    do: git(dir, home, ["push", "--quiet", Url.with_token(project, secret), refspec])

  test "a push with a branch token and a clone with a reader token give the real bytes", c do
    {secret, _} = token!(c.project)
    dir = clone!(Url.with_token(c.project, secret), c.home, "ticket/1")
    {_sha, oid} = commit_lfs!(dir, c.home, "sound.bin", "REAL BYTES")

    assert {out, 0} = push(dir, c.home, c.project, secret)
    assert File.read!(elem(Lfs.path(c.bare, oid), 1)) == "REAL BYTES", out

    # Beside the repository, and not in the artifact store.
    refute String.starts_with?(elem(Lfs.path(c.bare, oid), 1), Forge.Storage.Local.root())

    {reader, _} = token!(c.project, git: :reader)
    clone = clone!(Url.with_token(c.project, reader), c.home, "ticket/1")
    assert File.read!(Path.join(clone, "sound.bin")) == "REAL BYTES"
  end

  # --- Raw requests, for what a stock client will not send ---------------------------------------

  defp request(project, method, path, opts \\ []) do
    secret = Keyword.get(opts, :secret)
    auth = if secret, do: [auth: {:basic, "forge:" <> secret}], else: []

    response =
      Req.request!(
        [
          method: method,
          url: Url.for(project) <> path,
          headers: Keyword.get(opts, :headers, []),
          body: Keyword.get(opts, :body),
          retry: false,
          decode_body: false,
          redirect: false
        ] ++ auth
      )

    {response.status, response.body}
  end

  defp batch(project, secret, operation, objects, extra \\ %{}) do
    body = Jason.encode!(Map.merge(%{"operation" => operation, "objects" => objects}, extra))

    {status, resp} =
      request(project, :post, "/info/lfs/objects/batch",
        secret: secret,
        body: body,
        headers: [{"content-type", "application/vnd.git-lfs+json"}]
      )

    {status, if(status in [200, 413, 422, 409], do: Jason.decode!(resp), else: resp)}
  end

  defp put(project, secret, oid, size, body, headers \\ []),
    do:
      request(project, :put, "/info/lfs/objects/#{oid}?size=#{size}",
        secret: secret,
        body: body,
        headers: headers
      )

  defp incoming(bare), do: Path.wildcard(Path.join(Lfs.incoming_dir(bare), "*"))

  describe "an upload is kept only when it is whole" do
    test "wrong bytes of the right size leave nothing", c do
      {secret, _} = token!(c.project)
      oid = oid("the real bytes")

      assert {400, body} = put(c.project, secret, oid, 14, "the REAL bytes")
      assert body =~ "hash"
      refute Lfs.held?(c.bare, oid)
      assert incoming(c.bare) == []
    end

    test "a body of another length than the batch declared leaves nothing", c do
      {secret, _} = token!(c.project)
      oid = oid("the real bytes")

      # Said by Content-Length, which is refused before a byte is read.
      assert {400, _} = put(c.project, secret, oid, 100, "the real bytes")
      # Said by nothing but the bytes that arrive, shorter and longer, on a chunked body.
      for {size, body} <- [{100, ["the real ", "bytes"]}, {5, ["the real ", "bytes"]}] do
        assert {400, _} = put(c.project, secret, oid, size, body)
      end

      refute Lfs.held?(c.bare, oid)
      assert incoming(c.bare) == []
    end

    test "the right bytes are kept, and a second upload of them changes nothing", c do
      {secret, _} = token!(c.project)
      oid = oid("the real bytes")

      assert {200, ""} = put(c.project, secret, oid, 14, "the real bytes")
      assert File.read!(elem(Lfs.path(c.bare, oid), 1)) == "the real bytes"
      assert {200, ""} = put(c.project, secret, oid, 14, "the real bytes")
      assert incoming(c.bare) == []
    end

    test "an object above the limit is refused at the batch, naming the limit and its size", c do
      limit_to(10)
      {secret, _} = token!(c.project)

      assert {200, %{"objects" => [object]}} =
               batch(c.project, secret, "upload", [%{"oid" => oid("x"), "size" => 11}])

      assert %{"error" => %{"code" => 422, "message" => message}} = object
      assert message =~ "11 bytes"
      assert message =~ "at most 10 bytes"
      refute Map.has_key?(object, "actions")

      # And the PUT itself, for a client that skips the batch.
      assert {413, body} = put(c.project, secret, oid("x"), 11, "xxxxxxxxxxx")
      assert body =~ "at most 10 bytes"
    end

    test "git lfs push of an object above the limit prints the limit and the size", c do
      limit_to(10)
      {secret, _} = token!(c.project)
      dir = clone!(Url.with_token(c.project, secret), c.home, "ticket/1")
      commit_lfs!(dir, c.home, "big.bin", "twelve bytes")

      assert {out, code} = push(dir, c.home, c.project, secret)
      assert code != 0
      assert out =~ "at most 10 bytes"
      assert out =~ "12 bytes"
    end
  end

  defp limit_to(bytes) do
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :lfs_max_object_bytes, bytes))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)
  end

  describe "one project's objects are not another's" do
    setup c do
      other_bare = seeded_repo()
      name = "other#{System.unique_integer([:positive])}"
      {:ok, other} = register_owned!(%{name: name, repo_path: other_bare, default_branch: "main"})
      {other_secret, _} = token!(other, git: :reader)
      Map.merge(c, %{other: other, other_bare: other_bare, other_secret: other_secret})
    end

    test "an oid project A holds is 404 through B, by GET and by batch", c do
      oid = store!(c.bare, "A's bytes")
      {secret, _} = token!(c.project, git: :reader)

      assert {200, "A's bytes"} =
               request(c.project, :get, "/info/lfs/objects/#{oid}", secret: secret)

      assert {404, _} = request(c.other, :get, "/info/lfs/objects/#{oid}", secret: c.other_secret)

      assert {200, %{"objects" => [%{"error" => %{"code" => 404}}]}} =
               batch(c.other, c.other_secret, "download", [%{"oid" => oid, "size" => 9}])

      assert {200, %{"objects" => [%{"actions" => %{"download" => _}}]}} =
               batch(c.project, secret, "download", [%{"oid" => oid, "size" => 9}])
    end

    test "a malformed or traversing oid is 404 and reaches no file", c do
      {secret, _} = token!(c.project, git: :reader)
      store!(c.bare, "A's bytes")
      File.write!(Path.join(c.bare, "secret.txt"), "not an object")

      for bad <- [
            "..",
            "%2e%2e",
            "..%2f..%2fsecret.txt",
            String.upcase(oid("A's bytes")),
            "abc",
            String.duplicate("g", 64)
          ] do
        assert {404, _} = request(c.project, :get, "/info/lfs/objects/#{bad}", secret: secret)
      end

      assert {200, %{"objects" => [%{"error" => %{"code" => 422}}]}} =
               batch(c.project, secret, "download", [%{"oid" => "../../secret.txt", "size" => 1}])
    end
  end

  describe "who may download and who may upload" do
    test "a reader downloads and is refused an upload; every token that may push uploads", c do
      stored = store!(c.bare, "held")
      object = [%{"oid" => oid("new"), "size" => 3}]

      {reader, _} = token!(c.project, git: :reader)

      assert {200, %{"objects" => [%{"actions" => %{"download" => _}}]}} =
               batch(c.project, reader, "download", [%{"oid" => stored, "size" => 4}])

      assert {401, _} = batch(c.project, reader, "upload", object)
      assert {401, _} = put(c.project, reader, oid("new"), 3, "new")
      refute Lfs.held?(c.bare, oid("new"))

      for opts <- [
            [ref: "refs/heads/ticket/1"],
            [git: :developer],
            [git: :admin],
            [ref: Tokens.default_ref(c.project)]
          ] do
        {secret, _} = token!(c.project, opts)

        assert {200, %{"objects" => [%{"actions" => %{"upload" => _}}]}} =
                 batch(c.project, secret, "upload", object)

        assert {200, _} = put(c.project, secret, oid("new"), 3, "new")
        File.rm!(elem(Lfs.path(c.bare, oid("new")), 1))
      end
    end

    test "a job's token uploads, and is answered at the address a worker dials", c do
      # A worker dials another address than a person does, as on a machine of its own.
      config = Application.get_env(:forge, Forge.Jobs)

      Application.put_env(
        :forge,
        Forge.Jobs,
        Keyword.put(config, :platform_url, "http://platform.internal:4000")
      )

      on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

      {person, _} = token!(c.project)

      assert {200, %{"objects" => [%{"actions" => %{"upload" => %{"href" => href}}}]}} =
               batch(c.project, person, "upload", [%{"oid" => oid("new"), "size" => 3}])

      assert href == Url.for(c.project) <> "/info/lfs/objects/#{oid("new")}?size=3"
      refute href =~ "platform.internal"

      ticket = ticket_fixture(%{project: c.project})
      job = job_fixture(%{ticket: ticket})
      {:ok, secret, _row} = Tokens.issue_for_job(job, ticket, c.project)

      assert {200, %{"objects" => [%{"actions" => %{"upload" => %{"href" => href}}}]}} =
               batch(c.project, secret, "upload", [%{"oid" => oid("new"), "size" => 3}])

      assert href ==
               "http://platform.internal:4000/git/#{c.project.name}.git/info/lfs/objects/#{oid("new")}?size=3"
    end

    test "no other credential gets either", c do
      oid = store!(c.bare, "held")
      object = [%{"oid" => oid, "size" => 4}]
      other_bare = seeded_repo()

      {:ok, other} =
        register_owned!(%{
          name: "x#{System.unique_integer([:positive])}",
          repo_path: other_bare,
          default_branch: "main"
        })

      {foreign, _} = token!(other, git: :admin)
      {none, _} = token!(c.project, git: :none, api: :write)
      {api_only, _} = token!(c.project, git: :none, api: :read)
      {reader, _} = token!(c.project, git: :reader)

      for secret <- [nil, "forged", foreign, none, api_only] do
        assert {401, _} = batch(c.project, secret, "download", object)
        assert {401, _} = request(c.project, :get, "/info/lfs/objects/#{oid}", secret: secret)
        assert {401, _} = put(c.project, secret, oid("zzz"), 3, "zzz")
      end

      # A bearer header and a session cookie are not what this endpoint reads.
      assert {401, _} =
               request(c.project, :get, "/info/lfs/objects/#{oid}",
                 headers: [{"authorization", "Bearer " <> reader}, {"cookie", "_forge_key=abc"}]
               )
    end
  end

  describe "the batch" do
    test "is bounded in objects and in body, and refuses what it cannot read", c do
      {secret, _} = token!(c.project)
      many = for n <- 1..1001, do: %{"oid" => oid("#{n}"), "size" => 1}
      assert {413, _} = batch(c.project, secret, "download", many)
      assert {200, _} = batch(c.project, secret, "download", Enum.take(many, 1000))

      # Exactly the bound is read; one byte over it, and far over it, is not (the second is handed
      # to the plug in pieces).
      exact = "{\"operation\":\"download\",\"objects\":[]}"
      padded = exact <> String.duplicate(" ", 1024 * 1024 - byte_size(exact))

      assert {200, _} =
               request(c.project, :post, "/info/lfs/objects/batch", secret: secret, body: padded)

      for size <- [1024 * 1024 + 1, 3 * 1024 * 1024] do
        assert {413, _} =
                 request(c.project, :post, "/info/lfs/objects/batch",
                   secret: secret,
                   body: String.duplicate(" ", size)
                 )
      end

      assert {422, _} =
               request(c.project, :post, "/info/lfs/objects/batch", secret: secret, body: "{nope")

      assert {422, _} = batch(c.project, secret, "delete", [])
      assert {409, _} = batch(c.project, secret, "download", [], %{"hash_algo" => "sha1"})
      # `basic` is the only transfer there is; a client that offers others and not it is refused.
      assert {422, _} = batch(c.project, secret, "download", [], %{"transfers" => ["tus"]})

      assert {200, _} =
               batch(c.project, secret, "download", [], %{"transfers" => ["tus", "basic"]})
    end

    test "an object exactly at the limit is accepted, and `batch` is not an oid", c do
      limit_to(10)
      {secret, _} = token!(c.project)

      assert {200, %{"objects" => [%{"actions" => %{"upload" => _}}]}} =
               batch(c.project, secret, "upload", [%{"oid" => oid("ten bytes!"), "size" => 10}])

      # An object at the limit is kept (the PUT's own bound, as the batch's is above).
      assert {200, _} = put(c.project, secret, oid("ten bytes!"), 10, "ten bytes!")

      # Neither a GET nor a PUT of the batch's own address is an object: both are 404, not the batch.
      assert {404, _} = request(c.project, :get, "/info/lfs/objects/batch", secret: secret)

      assert {404, _} =
               request(c.project, :put, "/info/lfs/objects/batch?size=1",
                 secret: secret,
                 body: "x"
               )
    end

    test "an empty object is an object, and a size that is no number is refused", c do
      {secret, _} = token!(c.project)

      assert {200, %{"objects" => [%{"actions" => %{"upload" => _}}]}} =
               batch(c.project, secret, "upload", [%{"oid" => oid(""), "size" => 0}])

      assert {200, _} = put(c.project, secret, oid(""), 0, "")
      assert Lfs.held?(c.bare, oid(""))
      assert {400, _} = put(c.project, secret, oid("x"), "abc", "x")
      # No Content-Length to catch it: the size alone is what is read.
      assert {400, _} =
               put(
                 c.project,
                 secret,
                 oid("x"),
                 String.duplicate("9", 25),
                 Stream.map(["x"], & &1)
               )
    end

    test "decides nothing by the ref it is told", c do
      {secret, _} = token!(c.project)

      assert {200, %{"objects" => [%{"actions" => %{"upload" => _}}]}} =
               batch(c.project, secret, "upload", [%{"oid" => oid("n"), "size" => 1}], %{
                 "ref" => %{"name" => "refs/heads/ticket/2"}
               })
    end

    test "an upload of an object already held gets no action and restarts its clock", c do
      oid = store!(c.bare, "held")
      path = elem(Lfs.path(c.bare, oid), 1)
      File.touch!(path, 1_000_000)
      {secret, _} = token!(c.project)

      assert {200, %{"objects" => [object]}} =
               batch(c.project, secret, "upload", [%{"oid" => oid, "size" => 4}])

      refute Map.has_key?(object, "actions")
      assert File.stat!(path, time: :posix).mtime > 1_000_000
    end

    test "carries the token in a header and never in an address or a log", c do
      {secret, row} = token!(c.project)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {200, %{"objects" => [%{"actions" => %{"upload" => action}}]}} =
            batch(c.project, secret, "upload", [%{"oid" => oid("n"), "size" => 1}])

          refute action["href"] =~ secret
          refute action["href"] =~ "@"

          assert action["header"]["Authorization"] ==
                   "Basic " <> Base.encode64("forge:" <> secret)

          put(c.project, secret, oid("n"), 99, "no")
        end)

      refute log =~ secret
      refute log =~ Base.encode64("forge:" <> secret)
      assert Repo.get!(Forge.Git.Token, row.id).last_used_via == :git
    end

    test "locking answers 501 to a token and is not offered to anyone else", c do
      {secret, _} = token!(c.project, git: :reader)

      assert {501, _} =
               request(c.project, :post, "/info/lfs/locks/verify", secret: secret, body: "{}")

      assert {501, _} = request(c.project, :get, "/info/lfs/locks", secret: secret)
      assert {401, _} = request(c.project, :get, "/info/lfs/locks")
      assert {404, _} = request(c.project, :get, "/info/lfs/else", secret: secret)
    end
  end
end
