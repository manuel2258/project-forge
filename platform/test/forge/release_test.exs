defmodule Forge.ReleaseTest do
  use Forge.DataCase, async: false

  import ExUnit.CaptureIO
  import Forge.ForgeFixtures

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
        Path.join(System.tmp_dir!(), "#{name}.git"),
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
      Release.register_project(name, Path.join(System.tmp_dir!(), "#{name}.git"))
    end)

    assert Forge.Projects.role(Forge.Projects.by_name(name), admin) == :admin
  end

  test "add_member repairs a project whose admins are gone" do
    owner = Forge.AccountsFixtures.user_fixture()
    name = "rel-#{System.unique_integer([:positive])}"

    capture_io(fn ->
      Release.register_project(
        name,
        Path.join(System.tmp_dir!(), "#{name}.git"),
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

  test "approve_user lets the first account in, with no node admin to approve it" do
    pending = Forge.AccountsFixtures.pending_user_fixture()

    capture_io(fn -> Release.approve_user(pending.email) end)

    assert Accounts.User.active?(Accounts.get_user!(pending.id))
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
end
