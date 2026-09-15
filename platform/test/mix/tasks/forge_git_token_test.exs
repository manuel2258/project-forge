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
    refute token.write
    assert token.ref == nil
    assert token.ticket_id == nil
  end

  test "--ticket scopes the credential to that ticket's branch" do
    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 4, branch: "ticket/4"})

    Token.run([project.name, "--ticket", "4"])

    assert [token] = Tokens.list(project)
    assert token.write
    assert token.ref == "refs/heads/ticket/4"
    assert token.ticket_id == ticket.id
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
end
