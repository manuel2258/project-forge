defmodule Forge.Merge do
  @moduledoc """
  Merging a ticket's approved changeset into its project's default branch.

  Entirely in the object database: `merge-tree` is a real three-way merge from the merge base
  with no checkout and no temporary worktree, and a non-zero exit lists the conflicted paths, so
  detecting a conflict costs nothing when there is none.

  The result is then **pushed into the bare repository by path** rather than written with
  `update-ref`. Pushing over the local transport spawns `receive-pack`, which runs the
  repository's own hooks — so the merge is guarded and mirrored by exactly the code path a job's
  push takes, rather than by a second implementation beside it.

  `perform/2` is idempotent: an approved commit already on the default branch is left alone. See
  `docs/design/git-hosting.md`.
  """

  alias Forge.Accounts.User
  alias Forge.Artifacts
  alias Forge.Git
  alias Forge.Jobs
  alias Forge.Jobs.Job
  alias Forge.Projects
  alias Forge.Projects.Project
  alias Forge.Tickets
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  @type outcome ::
          {:ok, %{sha: String.t(), already: boolean()}}
          | {:conflict, [String.t()]}
          | {:error, term()}

  @doc """
  Whether the ticket's approved changeset would merge cleanly. Reads the object database and
  changes nothing, so it is safe to call before a transaction that must not be rolled back.
  """
  @spec check(Ticket.t()) :: :ok | {:conflict, [String.t()]} | {:error, term()}
  def check(%Ticket{} = ticket) do
    with {:ok, plan} <- ticket_plan(ticket), do: check_refs(plan)
  end

  @doc """
  Whether a conversation's branch would merge cleanly into the default branch.

  This is the second route into the default branch, which `pre-receive` exists to keep singular,
  so it is worth being exact: both routes are the platform's own merge, both are guarded by the
  same hook with `FORGE_INTERNAL`, and neither lets a client write the default branch. What
  differs is what authorises it — a ticket's approved changeset version, or an operator pressing
  merge on a diff they are looking at.
  """
  @spec check_chat(Job.t()) :: :ok | {:conflict, [String.t()]} | {:error, term()}
  def check_chat(%Job{kind: :chat} = chat) do
    with {:ok, plan} <- chat_plan(chat), do: check_refs(plan)
  end

  defp check_refs(%{repo: repo, head: head, source: source}), do: dry_run(repo, head, source)

  defp dry_run(repo, head, approved) do
    if Git.ancestor?(repo, approved, head) do
      :ok
    else
      forget_tree(merge_tree(repo, head, approved))
    end
  end

  # The tree `merge-tree` wrote is not wanted here: a check has no result but whether it worked.
  # It is an unreferenced object and git collects it like any other.
  defp forget_tree({:ok, _tree}), do: :ok
  defp forget_tree(other), do: other

  @doc "Merges the approved changeset and pushes it, as `user`."
  @spec perform(Ticket.t(), User.t() | nil) :: outcome()
  def perform(%Ticket{} = ticket, user \\ nil) do
    with {:ok, plan} <- ticket_plan(ticket), do: perform_refs(plan, user)
  end

  @doc """
  Merges a conversation's branch and pushes it, as `user`, then deletes the branch.

  **The branch is deleted only after the pin exists.** `refs/forge/chat/<id>` is what keeps the
  merged commit reachable; deleting `chat/<id>` first would leave the commit collectable between
  the two, and "the branch is deleted when done" would quietly mean the work was too.
  """
  @spec perform_chat(Job.t(), User.t() | nil) :: outcome()
  def perform_chat(%Job{kind: :chat} = chat, user \\ nil) do
    with {:ok, plan} <- chat_plan(chat),
         {:ok, result} <- perform_refs(plan, user) do
      Git.delete_branch(plan.repo, Jobs.chat_branch(chat))
      {:ok, result}
    end
  end

  defp perform_refs(plan, user) do
    %{repo: repo, head: head, source: source} = plan
    Git.pin(repo, plan.pin, source)

    if Git.ancestor?(repo, source, head) do
      {:ok, %{sha: head, already: true}}
    else
      merge(plan, user)
    end
  end

  @doc "Whether the ticket's approved changeset is already on the default branch."
  @spec merged?(Ticket.t()) :: boolean()
  def merged?(%Ticket{} = ticket) do
    case ticket_plan(ticket) do
      {:ok, %{repo: repo, head: head, source: source}} -> Git.ancestor?(repo, source, head)
      {:error, _reason} -> false
    end
  end

  @doc "Whether a conversation's branch is already on the default branch."
  @spec merged_chat?(Job.t()) :: boolean()
  def merged_chat?(%Job{kind: :chat} = chat) do
    case chat_plan(chat) do
      {:ok, %{repo: repo, head: head, source: source}} -> Git.ancestor?(repo, source, head)
      {:error, _reason} -> false
    end
  end

  @doc "The commit an approval of `changeset` pinned, or an error naming why there is none."
  @spec approved_sha(Ticket.t()) :: {:ok, String.t()} | {:error, term()}
  def approved_sha(%Ticket{} = ticket) do
    case Artifacts.latest(ticket.id, Workflow.changeset_artifact()) do
      nil -> {:error, :no_changeset}
      %{blob_uri: "git:" <> sha} -> {:ok, sha}
      %{blob_uri: other} -> {:error, {:not_a_commit, other}}
    end
  end

  # -- internals -------------------------------------------------------------------------------

  # What a merge needs, whatever authorised it: the repository, where it is going, what is being
  # merged, the ref that keeps it reachable, and what the commit should say.
  defp ticket_plan(%Ticket{} = ticket) do
    project = Tickets.project_of(ticket)
    repo = Projects.repo_path(project)

    with {:ok, approved} <- approved_sha(ticket),
         {:ok, source} <- resolve_approved(repo, approved),
         {:ok, head} <- Git.resolve(repo, "refs/heads/" <> project.default_branch) do
      {:ok,
       %{
         repo: repo,
         project: project,
         head: head,
         source: source,
         pin: "refs/forge/approved/#{ticket.number}",
         message: fn user -> ticket_message(project, ticket, source, user) end
       }}
    end
  end

  defp chat_plan(%Job{} = chat) do
    project = Projects.get!(chat.project_id)
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    with {:ok, source} <- Git.resolve(repo, "refs/heads/" <> branch),
         {:ok, head} <- Git.resolve(repo, "refs/heads/" <> project.default_branch) do
      {:ok,
       %{
         repo: repo,
         project: project,
         head: head,
         source: source,
         pin: "refs/forge/chat/#{chat.id}",
         message: fn user -> chat_message(project, chat, source, user) end
       }}
    end
  end

  # A ticket branch may be rewritten, so the commit an approval pinned can in principle be gone.
  # Refusing loudly is the point: merging the branch head instead would merge something nobody
  # approved.
  defp resolve_approved(repo, sha) do
    case Git.resolve(repo, sha) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _reason} -> {:error, {:approved_commit_gone, sha}}
    end
  end

  defp merge(%{repo: repo, project: project, head: head, source: source} = plan, user) do
    with {:ok, tree} <- merge_tree(repo, head, source),
         {:ok, sha} <- commit_tree(repo, tree, head, source, plan.message.(user), user),
         :ok <- push(repo, project, sha) do
      {:ok, %{sha: sha, already: false}}
    end
  end

  # `merge-tree --write-tree` prints the merged tree, then — on a conflict, exit 1 — a block of
  # `<mode> <oid> <stage>\t<path>` lines, then its messages.
  defp merge_tree(repo, head, approved) do
    case Git.run(repo, ["merge-tree", "--write-tree", "--messages", head, approved],
           stderr: :separate
         ) do
      {:ok, out} ->
        {:ok, out |> String.split("\n", parts: 2) |> hd() |> String.trim()}

      {:error, {1, out}} ->
        {:conflict, conflicted_paths(out)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conflicted_paths(out) do
    out
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [_info, path] -> [path]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  # Both parents, so the ticket's own commits are reachable from the default branch afterwards
  # and `git log <branch>` says where the change came from. One parent would put the merged
  # content on the branch while losing every commit that produced it.
  defp commit_tree(repo, tree, head, source, message, user) do
    args = ["commit-tree", tree, "-p", head, "-p", source, "-m", message]

    case Git.run(repo, args, env: author(user), stderr: :separate) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Who approved is recorded in git itself, so it survives the platform. The *committer* is
  # always the platform, and always stated: `commit-tree` with no committer falls back to the
  # host's passwd entry and its hostname, which is a different commit on every host and no
  # commit at all somewhere that has neither — a container image, where `git` then fails with
  # "unable to auto-detect email address". `Git.create_root_commit/2` already states all four;
  # this is the same rule at the other site that makes commits.
  @committer [{"GIT_COMMITTER_NAME", "forge"}, {"GIT_COMMITTER_EMAIL", "forge@localhost"}]

  defp author(nil), do: @committer

  defp author(%User{email: email}) do
    [{"GIT_AUTHOR_NAME", email}, {"GIT_AUTHOR_EMAIL", email}] ++ @committer
  end

  defp ticket_message(%Project{name: name}, %Ticket{} = ticket, approved, user) do
    """
    Merge #{ticket.branch}: #{ticket.title}

    Ticket: #{name}##{ticket.number}
    Changeset: #{approved}
    Approved-by: #{(user && user.email) || "the engine"}
    """
  end

  # A conversation has no number and no approved version, so what authorised this is the person
  # who pressed merge on a diff they were looking at — which is what the message says.
  defp chat_message(%Project{name: name}, %Job{} = chat, source, user) do
    """
    Merge chat/#{chat.id}

    Project: #{name}
    Commit: #{source}
    Merged-by: #{(user && user.email) || "the engine"}
    """
  end

  # FORGE_INTERNAL is what `pre-receive` accepts as authority over the default branch. It is set
  # here and nowhere else, and the git endpoint removes it from every child it spawns.
  defp push(repo, %Project{default_branch: default}, sha) do
    env = [{"FORGE_INTERNAL", "1"}]

    case Git.run(repo, ["push", "--quiet", ".", "#{sha}:refs/heads/#{default}"], env: env) do
      {:ok, _out} -> :ok
      {:error, reason} -> {:error, {:push_refused, reason}}
    end
  end
end
