defmodule Mix.Tasks.Forge.Git.TokenTest do
  @moduledoc """
  `mix forge.git.token` is the second place the read-only rule is written down.

  `Forge.Release.git_token/2` says it for the release and `scope/2` here says it for the devshell,
  in the same words — "Without `--ticket` the token may only read" — and in two separate pieces of
  code. Both are covered, because a rule duplicated in two places fails in whichever of them
  nobody is looking at.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.Git.Tokens
  alias Mix.Tasks.Forge.Git.Token

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  # The printed line is `writes #{token.ref || "nothing"}`, so a token that gained `write: true`
  # but no ref still prints "writes nothing" — the output says the right thing about a credential
  # that can push anywhere. The row is the only witness that cannot be fooled.
  test "without --ticket the issued credential cannot write" do
    project = project_fixture()

    Token.run([project.name])

    assert [token] = Tokens.list(project)
    refute token.git_access in [:branch, :developer, :admin]
    assert token.ref == nil
    assert token.ticket_id == nil
  end

  test "--ticket scopes the credential to that ticket's branch" do
    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 4, branch: "ticket/4"})

    Token.run([project.name, "--ticket", "4"])

    assert [token] = Tokens.list(project)
    assert token.git_access == :branch
    assert token.ref == "refs/heads/ticket/4"
    assert token.ticket_id == ticket.id
  end

  test "--git, --api, --days and --name issue a project token and say what it may do" do
    project = project_fixture()
    ticket_fixture(%{project: project, number: 4, branch: "ticket/4"})

    Token.run([
      project.name,
      "--git",
      "developer",
      "--api",
      "write",
      "--days",
      "30",
      "--name",
      "ci"
    ])

    assert [token] = Tokens.list(project)
    assert %{name: "ci", git_access: :developer, api_access: :write, ref: nil} = token

    assert DateTime.diff(token.expires_at, DateTime.utc_now()) in (30 * 86_400 - 60)..(30 * 86_400)

    assert_received {:mix_shell, :info, [clone]}
    assert clone =~ "/git/#{project.name}.git"
    assert_received {:mix_shell, :info, ["api token: " <> secret]}
    assert {:ok, %{id: id}} = Tokens.authenticate_api(secret)
    assert id == token.id
    assert_received {:mix_shell, :info, [said]}
    assert said =~ "developer, writes every open ticket's branch"
    assert said =~ "api: write"
  end

  test "an API-only token prints no clone URL, and a ceiling is kept" do
    project = project_fixture()

    Token.run([project.name, "--git", "none", "--api", "read"])
    assert_received {:mix_shell, :info, ["api token: " <> _secret]}
    refute_received {:mix_shell, :info, ["http" <> _url]}

    assert_raise Mix.Error, fn -> Token.run([project.name, "--days", "366"]) end
    assert [_one] = Tokens.list(project)
  end

  # `--minutes` shares the `case` the write scope is decided in, so a rearrangement that loses the
  # read-only branch is just as likely to lose this one.
  test "--minutes sets the lifetime, with or without a ticket" do
    project = project_fixture()
    before = DateTime.utc_now()

    Token.run([project.name, "--minutes", "5"])

    assert [token] = Tokens.list(project)
    assert DateTime.diff(token.expires_at, before) in 240..300
  end

  # The words are the whole of what the operator is told a credential may do, and they are written
  # once per access, so each one is read back on its own — `developer` in the test above.
  describe "the line that says what the credential may do" do
    setup do
      project = project_fixture()
      ticket_fixture(%{project: project, number: 4, branch: "ticket/4"})
      %{project: project}
    end

    test "admin names the default branch", %{project: project} do
      Token.run([project.name, "--git", "admin"])
      assert said() =~ "git: admin, writes every open ticket's branch and the default branch,"
    end

    test "a ticket's token names its branch", %{project: project} do
      Token.run([project.name, "--ticket", "4"])
      assert said() =~ "git: writes refs/heads/ticket/4,"
    end

    test "the default branch's token names that branch", %{project: project} do
      Token.run([project.name, "--default"])
      assert said() =~ "git: writes #{Tokens.default_ref(project)},"
    end

    test "reader and none are said as they are", %{project: project} do
      Token.run([project.name])
      assert said() =~ "git: reader, api: none,"

      Token.run([project.name, "--git", "none", "--api", "read"])
      assert said() =~ "git: none, api: read,"
    end

    test "a token without API access prints no api token line", %{project: project} do
      Token.run([project.name, "--api", "none"])
      refute_received {:mix_shell, :info, ["api token: " <> _secret]}
    end
  end

  defp said do
    assert_received {:mix_shell, :info, [line]} when binary_part(line, 0, 4) == "git:"
    line
  end
end
