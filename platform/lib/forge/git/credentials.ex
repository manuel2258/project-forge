defmodule Forge.Git.Credentials do
  @moduledoc """
  The credential a mirror pushes with, in git's own store format, one file per mirror under a
  directory of the project's own.

  `docs/design/git-hosting.md` § The credential. Outside the repositories tree, because the bare
  repositories are what gets backed up and a token in one of them is a token in every backup.

  **One file per mirror rather than one store for the node.** git's store matches on protocol and
  host, so a single file could hold only one credential per host — two mirrors on `github.com`
  under different tokens would silently share the first one. The hook derives the same path from
  its own working directory; the rule that builds it therefore exists in two languages, and
  `Forge.GitCredentialsTest` and the hook's own end-to-end test are what keep them agreeing.

  **`<dir>/<project>/<mirror>.credentials`, a directory per project rather than a
  `<project>-<mirror>` filename.** Both names admit hyphens, so the flat form is ambiguous:
  project `a` with mirror `b-c` and project `a-b` with mirror `c` name one file. Two projects
  would then overwrite and delete each other's credentials, and — because git's store matches on
  host, not on who wrote the line — a push from one project would be handed the other project's
  token. Neither a project name nor a mirror name may contain `/`, so the subdirectory is
  unambiguous by construction rather than by escaping. Both halves derive it, so both were
  changed together.

  **They agree only when the project's `repo_path` (see `Forge.Projects.repo_path/1`) is
  `<repos_dir>/<name>.git`** — the address `Forge.Projects.register_named/3` guarantees and
  `Forge.Projects.register/2` does not. `Forge.Projects.put_mirror/5` is what enforces that
  invariant, refusing `{:error, :repo_path_not_standard}` before a token is ever written for a
  project registered somewhere else; nothing in this module or in the hook checks it, because
  neither one knows the project's row.
  """

  alias Forge.Projects
  alias Forge.Projects.Project

  @doc "Where every mirror credential for this node lives."
  @spec dir() :: String.t()
  def dir, do: Path.join(Path.dirname(Projects.repos_dir()), "mirror-credentials")

  @doc "The file holding one mirror's credential."
  @spec path(Project.t(), String.t()) :: String.t()
  def path(%Project{name: project}, mirror),
    do: Path.join([dir(), project, mirror <> ".credentials"])

  @doc """
  Writes the credential for one mirror, or removes it when there is no token.

  The username is optional because a host authenticating by token ignores it, but the store's
  format has a slot for it, so an absent one becomes `forge`.
  """
  @spec put(Project.t(), String.t(), String.t() | nil, String.t() | nil, String.t()) ::
          :ok | {:error, term()}
  def put(project, mirror, _user, token, _url) when token in [nil, ""],
    do: delete(project, mirror)

  def put(%Project{} = project, mirror, user, token, url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    user = if user in [nil, ""], do: "forge", else: user
    authority = if port && port != URI.default_port(scheme), do: "#{host}:#{port}", else: host
    line = "#{scheme}://#{escape(user)}:#{escape(token)}@#{authority}\n"

    write(path(project, mirror), line)
  end

  @doc "Removes a mirror's credential. Fine when there was none."
  @spec delete(Project.t(), String.t()) :: :ok
  def delete(%Project{} = project, mirror) do
    File.rm(path(project, mirror))
    :ok
  end

  # Percent-encoding, not form encoding: `URI.encode_www_form/1` turns a space into `+`, which
  # git would read literally.
  defp escape(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # Both directories are made 0700: `mkdir_p` creates the project's own as well as the node's,
  # and a mode that let anything else traverse either would list which projects and mirrors hold
  # a credential.
  defp write(path, line) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(dir(), 0o700),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(tmp, line),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, path)
    end
  end
end
