defmodule Forge.ReleaseTest do
  use Forge.DataCase, async: false

  import ExUnit.CaptureIO
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, Release}
  alias Forge.Git.Tokens

  test "generate_vapid_keys prints a usable pair" do
    output = capture_io(fn -> Release.generate_vapid_keys() end)

    assert [public, private] =
             output
             |> String.split("\n", trim: true)
             |> Enum.map(&(&1 |> String.split("=", parts: 2) |> List.last()))

    assert {:ok, <<4, _::binary-size(64)>>} = Base.url_decode64(public, padding: false)
    assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(private, padding: false)
  end

  # The deploy path. `docs/deploy.md` names these three, and a project registered without an
  # owner is invisible to everyone — so what is asserted is the membership row, not the output.
  test "register_project gives the project to the named owner" do
    owner = Forge.AccountsFixtures.user_fixture()
    name = "rel-#{System.unique_integer([:positive])}"

    capture_io(fn ->
      Release.register_project(
        name,
        Path.join(System.tmp_dir!(), "#{System.pid()}-#{name}.git"),
        "main",
        owner.email
      )
    end)

    project = Forge.Projects.by_name(name)
    assert Forge.Projects.role(project, owner) == :admin
  end

  test "register_project with no address falls to the node's only admin" do
    admin = Forge.AccountsFixtures.node_admin_fixture()
    name = "rel-#{System.unique_integer([:positive])}"

    capture_io(fn ->
      Release.register_project(name, Path.join(System.tmp_dir!(), "#{System.pid()}-#{name}.git"))
    end)

    assert Forge.Projects.role(Forge.Projects.by_name(name), admin) == :admin
  end

  test "add_member repairs a project whose admins are gone" do
    owner = Forge.AccountsFixtures.user_fixture()
    name = "rel-#{System.unique_integer([:positive])}"

    capture_io(fn ->
      Release.register_project(
        name,
        Path.join(System.tmp_dir!(), "#{System.pid()}-#{name}.git"),
        "main",
        owner.email
      )
    end)

    project = Forge.Projects.by_name(name)

    Forge.Repo.delete_all(from(m in Forge.Projects.Member, where: m.project_id == ^project.id))

    rescuer = Forge.AccountsFixtures.user_fixture()
    output = capture_io(fn -> Release.add_member(name, rescuer.email, "admin") end)

    assert output =~ rescuer.email
    assert Forge.Projects.role(project, rescuer) == :admin
  end

  # The repair for a permanent machine the upgrade could not give an owner — on a node with two
  # node admins it would not guess — without which it takes no work and only SQL could fix it.
  test "own_worker gives a machine with no owner one" do
    {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake", managed: false})
    owner = Forge.AccountsFixtures.user_fixture()

    output = capture_io(fn -> Release.own_worker(worker.id, owner.email) end)

    assert output =~ owner.email
    assert Forge.Workers.get(worker.id).user_id == owner.id

    # And never takes one away from its owner: that would move the right to put work on it.
    usurper = Forge.AccountsFixtures.user_fixture()
    assert Forge.Workers.adopt(worker, usurper) == {:error, :already_owned}
    assert Forge.Workers.get(worker.id).user_id == owner.id
  end

  # A deployed node has no Mix, so this is the only way its host mints a permanent machine
  # (`docs/design/identity.md` § Minting a permanent machine).
  test "new_worker mints a machine for the named user, into a project they are in" do
    put_platform_url("https://forge.example")
    owner = Forge.AccountsFixtures.user_fixture()
    name = "rel-#{System.unique_integer([:positive])}"
    repo_path = Path.join(tmp_dir("rel-worker"), "p.git")
    {:ok, project} = Forge.Projects.register(%{name: name, repo_path: repo_path}, owner)

    output = capture_io(fn -> Release.new_worker(owner.email, name) end)

    [_, id] = Regex.run(~r/^FORGE_WORKER_ID=(\S+)$/m, output)
    [_, token] = Regex.run(~r/^FORGE_WORKER_TOKEN=(\S+)$/m, output)
    assert {:ok, worker} = Forge.Workers.authenticate(id, token)
    assert worker.user_id == owner.id
    refute worker.managed
    assert [%{id: project_id}] = Forge.Workers.projects(worker)
    assert project_id == project.id
    assert output =~ ~r/^FORGE_PLATFORM_URL=https:\/\/forge.example$/m
  end

  test "new_worker with no project mints one that serves nothing until its owner assigns it" do
    put_platform_url("https://forge.example")
    owner = Forge.AccountsFixtures.user_fixture()

    output = capture_io(fn -> Release.new_worker(owner.email) end)

    [_, id] = Regex.run(~r/^FORGE_WORKER_ID=(\S+)$/m, output)
    worker = Forge.Workers.get(id)
    assert worker.user_id == owner.id
    assert Forge.Workers.projects(worker) == []
  end

  # The command asks the configured address and never the endpoint, which belongs to the running
  # service and is not started here.
  defp put_platform_url(url) do
    previous = Application.get_env(:forge, Forge.Jobs, [])
    Application.put_env(:forge, Forge.Jobs, Keyword.put(previous, :platform_url, url))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, previous) end)
  end

  test "approve_user lets the first account in, with no node admin to approve it" do
    pending = Forge.AccountsFixtures.pending_user_fixture()

    capture_io(fn -> Release.approve_user(pending.email) end)

    assert Accounts.User.active?(Accounts.get_user!(pending.id))
  end

  # The join an OIDC login refuses to make. The refusal is `Forge.IdentityTest`'s; this is the
  # host-side door, and it must reach `Accounts.link_identity/3` rather than reimplement it.
  test "link_identity attaches an identity to an account that already exists" do
    user = Forge.AccountsFixtures.user_fixture()

    output =
      capture_io(fn ->
        Release.link_identity(user.email, "https://issuer.example.test", "sub-77")
      end)

    assert output =~ user.email
    assert Accounts.get_user_by_identity("https://issuer.example.test", "sub-77").id == user.id
  end

  test "migrate is idempotent on a migrated database" do
    assert :ok = Release.migrate()
  end

  # `git_token/2` is what `docs/deploy.md` § First run tells an operator to paste into a clone
  # command, and both that guide and this module's doc promise the same thing: "Without a ticket
  # number the token may only read." The whole promise is one `nil -> []` branch.
  #
  # It cannot be tested through what the command prints. That line reads the token back —
  # `writes #{token.ref || "nothing"}` — and a token issued with `write: true` and no ref has no
  # ref to print, so the output still says "writes nothing" while the credential can push to
  # every ref in the project. The output would lie in exactly the case that matters, so the
  # assertion has to be on the row that was issued.
  test "a git token issued without a ticket may only read" do
    project = project_fixture()

    printed = capture_io(fn -> Release.git_token(project.name) end)

    assert [token] = Tokens.list(project)
    refute token.write
    assert token.ref == nil
    assert token.ticket_id == nil
    assert printed =~ "writes nothing"
  end

  # And the other half of the sentence: with a ticket the token may write "that ticket's branch,
  # and nothing else". A write token with the wrong ref — or with none, which the hooks read as
  # unrestricted — is the same failure seen from the other side.
  test "a git token issued for a ticket may write that ticket's branch and no other" do
    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 7, branch: "ticket/7"})

    printed = capture_io(fn -> Release.git_token(project.name, 7) end)

    assert [token] = Tokens.list(project)
    assert token.write
    assert token.ref == "refs/heads/ticket/7"
    assert token.ticket_id == ticket.id
    assert printed =~ "writes refs/heads/ticket/7"
  end

  # **The first account on a container node.** `create_operator/2` made a plain user, and on a
  # fresh node that is a dead end with no way out: `/accounts` is behind `require_node_admin` so
  # nobody can approve a second account, `register_project/2` resolves its owner through
  # `owner_for(nil)` and gets `:no_owner`, and the image turns distribution off so there is no
  # `forge remote` to reach the repo another way. The opts have to reach `Accounts`.
  test "create_operator seeds a node admin when told to" do
    email = "admin#{System.unique_integer([:positive])}@example.com"

    output =
      capture_io(fn ->
        Release.create_operator(email, "a sufficiently long password", node_admin: true)
      end)

    assert output =~ "created node admin #{email}"
    assert Accounts.get_user_by_email(email).node_admin
    assert {:ok, _admin} = Accounts.owner_for(nil)
  end

  # And the other half: the opts are what asks for it, so the ordinary call must still not.
  # A `node_admin: true` default would hand the accounts page to every account made from the
  # host, which is the same defect pointing the other way.
  test "create_operator makes an ordinary user when it is not told to" do
    email = "op#{System.unique_integer([:positive])}@example.com"

    output = capture_io(fn -> Release.create_operator(email, "a sufficiently long password") end)

    assert output =~ "created user #{email}"
    refute Accounts.get_user_by_email(email).node_admin
  end

  test "create_operator and create_token work against the repo" do
    email = "op#{System.unique_integer([:positive])}@example.com"

    assert capture_io(fn -> Release.create_operator(email, "a sufficiently long password") end) =~
             "created user #{email}"

    assert %{confirmed_at: %DateTime{}} = user = Accounts.get_user_by_email(email)

    assert Accounts.get_user_by_email_and_password(email, "a sufficiently long password").id ==
             user.id

    token = capture_io(fn -> Release.create_token(email, "phone") end) |> String.trim()
    assert Accounts.get_user_by_api_token(token).id == user.id

    assert capture_io(fn -> Release.list_tokens(email) end) =~ "phone\t"
    assert capture_io(fn -> Release.revoke_token(email, "phone") end) =~ "revoked 1 token"
    assert Accounts.get_user_by_api_token(token) == nil
    assert capture_io(fn -> Release.list_tokens(email) end) == ""
  end

  describe "mirrors" do
    # `owner_for(nil)` resolves to the node's only admin, so the project has to be owned by one
    # for `set_mirror/4` and `delete_mirror/2` — both host-side, with no logged-in user to be —
    # to have an actor to record.
    # `repos_dir` defaults to a single directory shared by the whole test environment, and
    # `register_named/3` addresses a project by name alone — a counter that restarts at a low
    # number on every `mix test` run. Without an override here, run N's project would leave its
    # bare repository (and whatever mirrors this describe block set on it) behind for run N+1's
    # same-named project to adopt. Pointing `repos_dir` at a fresh `node_repos_dir/0` per test avoids
    # both the name reuse and the leak, the way `test/forge/projects_mirror_test.exs` does.
    setup do
      admin = Forge.AccountsFixtures.node_admin_fixture()
      name = "rel-mirror-#{System.unique_integer([:positive])}"
      jobs_config = Application.get_env(:forge, Forge.Jobs)

      Application.put_env(
        :forge,
        Forge.Jobs,
        Keyword.put(jobs_config, :repos_dir, node_repos_dir())
      )

      # Captured now, while the override above is live: an `on_exit` that restored the config
      # first and read the credentials dir after would compute the *original* `repos_dir`.
      credentials_dir = Forge.Git.Credentials.dir()

      on_exit(fn ->
        Application.put_env(:forge, Forge.Jobs, jobs_config)
        File.rm_rf(credentials_dir)
      end)

      # `register_named/3`, not `register/2` with a fixture path: `put_mirror/5` refuses a
      # project whose repository is not at `<repos_dir>/<name>.git`.
      {:ok, project} = Forge.Projects.register_named(name, "main", admin)

      %{project: project, name: name}
    end

    test "set_mirror creates one, with the node's only admin as the actor", %{
      project: project,
      name: name
    } do
      printed =
        capture_io(fn -> Release.set_mirror(name, "github", "https://github.com/x/y.git") end)

      assert [%{name: "github", url: "https://github.com/x/y.git"}] =
               Forge.Projects.list_mirrors(project)

      assert printed =~ "https://github.com/x/y.git"
    end

    test "delete_mirror removes one", %{project: project, name: name} do
      capture_io(fn -> Release.set_mirror(name, "github", "https://github.com/x/y.git") end)

      printed = capture_io(fn -> Release.delete_mirror(name, "github") end)

      assert Forge.Projects.list_mirrors(project) == []
      assert printed =~ "removed"
    end
  end
end
