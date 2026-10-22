defmodule Forge.Merge do
  @moduledoc """
  Merging a ticket's changeset — the version its transition into the merging state named — or a
  conversation's branch into its project's default branch.

  Entirely in the object database: `merge-tree` is a real three-way merge from the merge base
  with no checkout and no temporary worktree, and a non-zero exit lists the conflicted paths, so
  detecting a conflict costs nothing when there is none.

  The result is then **pushed into the bare repository by path** rather than written with
  `update-ref`. Pushing over the local transport spawns `receive-pack`, which runs the
  repository's own hooks — so the merge is guarded and mirrored by exactly the code path a job's
  push takes, rather than by a second implementation beside it.

  **One commit, with one parent.** What lands is a single plain commit on the default branch whose
  only parent is the branch's previous head: the ticket's own run-by-run commits are not part of
  the default branch's ancestry afterwards, and what keeps the approved commit itself reachable is
  the `refs/forge/*` pin every attempt writes. See `docs/design/git-hosting.md` § The merge.

  `perform/4` is idempotent: it makes no second commit when merging would change nothing, which
  is asked of the merged tree rather than of reachability — see `merged_tree/3`.

  **What a ticket's merge merges, and what it says, are both named by its caller**, never read
  here as "the latest version": the transition into the merging state names the changeset commit
  and the `commit-message` version it was taken for, and the merge is of that one and says that
  one (`docs/design/workflow-grammar-v1.md` § Merging). `changeset/1` and
  `commit_message_version/1` are where the transition reads them.

  **Nothing here composes a message.** The text is an agent's, written as the `commit-message`
  document, and is used as it stands.

  **A merge that loses a race is retried once.** An attempt is written against the head it
  resolved; when it fails and the default branch has moved since, one more attempt is made
  against the new head, and what that returns is final. See `docs/design/git-hosting.md`
  § Where it runs, and what a conflict does.
  """

  alias Forge.Accounts.User
  alias Forge.Artifacts
  alias Forge.Conversations
  alias Forge.Git
  alias Forge.Jobs
  alias Forge.Jobs.Job
  alias Forge.Projects
  alias Forge.Projects.Project
  alias Forge.Tickets
  alias Forge.Tickets.Ticket
  alias ForgeCore.Document
  alias ForgeCore.Workflow

  @typedoc """
  A ticket's merge that conflicted: the paths, and the default branch's head it conflicted with —
  after the one retry, the head the retry was made against.
  """
  @type conflict :: {:conflict, [String.t()], String.t()}

  @type outcome :: {:ok, %{sha: String.t(), already: boolean()}} | conflict() | {:error, term()}

  @doc """
  The ticket's latest `changeset` version: its commit, its number and the row. What a transition
  into the merging state reads, once, as it is taken — and names, and a person's approval of it is
  recorded against, so the merge after it is of that version and no later one
  (`docs/design/workflow-grammar-v1.md` § Merging).
  """
  @spec changeset(Ticket.t()) ::
          {:ok, %{sha: String.t(), version: pos_integer(), row: struct()}}
          | {:error, term()}
  def changeset(%Ticket{} = ticket) do
    case Artifacts.latest(ticket.id, Workflow.changeset_artifact()) do
      nil ->
        {:error, :no_changeset}

      row ->
        case Artifacts.commit(row) do
          nil -> {:error, {:not_a_commit, row.blob_uri}}
          sha -> {:ok, %{sha: sha, version: row.version, row: row}}
        end
    end
  end

  @doc """
  The number of the ticket's latest `commit-message` version, or nil when it has none.

  Read once as a transition into the merging state is taken and named on its event, for the same
  reason the changeset is: what the merge commit says is what that version said, not what a
  conversation wrote over it between the approval and the entry action
  (`docs/design/workflow-grammar-v1.md` § Merging).
  """
  @spec commit_message_version(Ticket.t()) :: pos_integer() | nil
  def commit_message_version(%Ticket{} = ticket) do
    case Artifacts.latest(ticket.id, Workflow.commit_message_artifact()) do
      nil -> nil
      row -> row.version
    end
  end

  @doc """
  Whether `sha`, a commit of the ticket's, would merge cleanly into the default branch — at its
  head, or at `head` when one is given: a merge just made, or what it was made on top of, for
  `Forge.Merge.Watch`. Reads the object database and changes nothing, so it is safe to call before
  a transaction that must not be rolled back.
  """
  @spec check(Ticket.t(), String.t(), String.t() | nil) :: :ok | conflict() | {:error, term()}
  def check(%Ticket{} = ticket, sha, head \\ nil) do
    with {:ok, plan} <- ticket_plan(ticket, sha) do
      plan = if head, do: %{plan | head: head}, else: plan

      case check_refs(plan) do
        {:conflict, paths} -> {:conflict, paths, plan.head}
        other -> other
      end
    end
  end

  @doc """
  Whether a conversation's branch would merge cleanly into the default branch.

  This is the second route into the default branch, which `pre-receive` exists to keep singular,
  so it is worth being exact: both routes are the platform's own merge, both are guarded by the
  same hook with `FORGE_INTERNAL`, and neither lets a job write the default branch. What
  differs is what authorises it — the changeset version a ticket's transition named, or an operator pressing
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

  @doc """
  Merges `sha`, the commit the ticket's transition into its merging state named, as `user`, saying
  what version `message_version` of the ticket's `commit-message` says.

  `{:error, :no_commit_message}` when that version is absent, gone or blank: there is nothing for
  the commit to say, and the caller sticks the ticket rather than merging under a message nobody
  wrote.
  """
  @spec perform(Ticket.t(), String.t(), pos_integer() | nil, User.t() | nil) :: outcome()
  def perform(%Ticket{} = ticket, sha, message_version, user \\ nil) do
    with {:ok, plan} <- ticket_plan(ticket, sha),
         {:ok, message} <- ticket_commit_message(ticket, message_version) do
      perform_refs(%{plan | message: message}, user)
    end
  end

  @doc """
  Merges a conversation's branch and pushes it, as `user`, then deletes the branch.

  **The branch is deleted only after the pin exists.** `refs/forge/chat/<id>` is what keeps the
  merged commit reachable; deleting `chat/<id>` first would leave the commit collectable between
  the two, and "the branch is deleted when done" would quietly mean the work was too.

  What the commit says is the latest version of the conversation's own `commit-message` document,
  read at the click — the same "as it is when merge is pressed" rule the branch itself follows
  (`docs/design/conversations.md` § Commits). `{:error, :no_commit_message}` when there is none,
  which is why the page offers no merge until there is.
  """
  @spec perform_chat(Job.t(), User.t() | nil) ::
          {:ok, %{sha: String.t(), already: boolean()}}
          | {:conflict, [String.t()]}
          | {:error, term()}
  def perform_chat(%Job{kind: :chat} = chat, user \\ nil) do
    with {:ok, plan} <- chat_plan(chat),
         {:ok, message} <- chat_commit_message(chat) do
      case perform_refs(%{plan | message: message}, user) do
        {:ok, result} ->
          Git.delete_branch(plan.repo, Jobs.chat_branch(chat))
          {:ok, result}

        {:conflict, paths, _head} ->
          {:conflict, paths}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  What closing a conversation does to its branch. `docs/design/conversations.md` § Lifetime has
  the rule and the reasons; in short:

  - **merged** — its head is on the default branch: pinned at `refs/forge/chat/<id>`, then
    deleted, in the order `perform_chat/2` uses and for its reason;
  - **unmerged, and it would merge cleanly** — deleted, with nothing pinned. This is the abandon:
    the person had a merge that worked and ended the conversation instead, and the commits
    become collectable;
  - **it would not merge cleanly** — kept. A merge that conflicted deletes nothing, because the
    branch is where the work still is, and taking the change by hand needs it;
  - **already gone** — nothing.

  The conflict is asked of the merge itself (`merge-tree`, as `check_chat/1` does) rather than of
  a record that a merge once failed: a guard must use the model of the operation it guards.
  """
  @spec abandon_chat(Job.t()) ::
          {:ok, {:deleted, :merged | :unmerged, String.t()} | {:kept, :conflict, String.t()}}
          | {:ok, :gone}
          | {:error, term()}
  def abandon_chat(%Job{kind: :chat} = chat) do
    repo = chat.project_id |> Projects.get!() |> Projects.repo_path()
    branch = Jobs.chat_branch(chat)

    if Git.branch_exists?(repo, branch) do
      with {:ok, plan} <- chat_plan(chat), do: abandon(plan, branch)
    else
      {:ok, :gone}
    end
  end

  defp abandon(%{repo: repo, head: head, source: source} = plan, branch) do
    if already_merged?(repo, head, source) do
      # Pin, then delete. Which comes first is not something a test can see — both have happened
      # by the time anything looks — so swapping them is an equivalent mutant as far as the suite
      # can tell. It matters to a `git gc` that runs between the two, which is the case § Commits
      # names for `perform_chat/2`.
      with :ok <- Git.pin(repo, plan.pin, source),
           :ok <- Git.delete_branch(repo, branch) do
        {:ok, {:deleted, :merged, source}}
      end
    else
      plan |> check_refs() |> abandon_unmerged(repo, branch, source)
    end
  end

  defp abandon_unmerged(:ok, repo, branch, source) do
    with :ok <- Git.delete_branch(repo, branch), do: {:ok, {:deleted, :unmerged, source}}
  end

  defp abandon_unmerged({:conflict, _paths}, _repo, _branch, source),
    do: {:ok, {:kept, :conflict, source}}

  defp abandon_unmerged({:error, reason}, _repo, _branch, _source), do: {:error, reason}

  # One attempt, and one more when the default branch moved while the first was being written.
  #
  # The retry is decided by the ref, read exactly as the plan read it, because that is what the
  # push asserts: a fast-forward of the head the attempt found. An unmoved branch means the failure
  # was something a second attempt would meet again — a conflict with the newest head there is,
  # a hook's refusal, a repository that is not there — so it is returned as it is. The head that
  # decided the retry is the head it is made against.
  defp perform_refs(plan, user) do
    case attempt(plan, user) do
      {:ok, _merged} = merged ->
        merged

      failed ->
        case default_head(plan.repo, plan.project) do
          {:ok, head} when head != plan.head -> %{plan | head: head} |> attempt(user) |> at(head)
          _unmoved -> at(failed, plan.head)
        end
    end
  end

  # A conflict says which head it was found against, because that is what the job sent to resolve
  # it has to merge and what the event records.
  defp at({:conflict, paths}, head), do: {:conflict, paths, head}
  defp at(other, _head), do: other

  defp attempt(plan, user) do
    %{repo: repo, head: head, source: source} = plan
    Git.pin(repo, plan.pin, source)

    case merged_tree(repo, head, source) do
      :already -> {:ok, %{sha: head, already: true}}
      {:ok, tree} -> merge(plan, tree, user)
      conflict_or_error -> conflict_or_error
    end
  end

  # **What a merge would land, or `:already` when it would land nothing.**
  #
  # Reachability used to answer this — a merged commit had the source as its second parent, so
  # `Git.ancestor?(repo, source, head)` was true afterwards. One parent ends that: a commit this
  # module has just merged is reachable only through its `refs/forge/*` pin, and asking whether it
  # is an ancestor of the default branch would answer "no" for ever, so every retried `perform/4`
  # would make another content-identical commit.
  #
  # The merged tree answers it instead, and answers it for both shapes at once: merging changes
  # nothing exactly when the three-way merge resolves to the head's own tree — true when `source`
  # is a literal ancestor, which is every ticket merged under the old two-parent shape and needs
  # no migration, and true when `source`'s whole diff already landed as one squash commit.
  defp merged_tree(repo, head, source) do
    case merge_tree(repo, head, source) do
      {:ok, tree} -> if Git.tree(repo, head) == {:ok, tree}, do: :already, else: {:ok, tree}
      conflict_or_error -> conflict_or_error
    end
  end

  defp already_merged?(repo, head, source), do: merged_tree(repo, head, source) == :already

  defp default_head(repo, %Project{default_branch: default}),
    do: Git.resolve(repo, "refs/heads/" <> default)

  @doc "Whether the ticket's latest changeset is already on the default branch."
  @spec merged?(Ticket.t()) :: boolean()
  def merged?(%Ticket{} = ticket) do
    with {:ok, %{sha: sha}} <- changeset(ticket),
         {:ok, %{repo: repo, head: head, source: source}} <- ticket_plan(ticket, sha) do
      already_merged?(repo, head, source)
    else
      {:error, _reason} -> false
    end
  end

  @doc "Whether a conversation's branch is already on the default branch."
  @spec merged_chat?(Job.t()) :: boolean()
  def merged_chat?(%Job{kind: :chat} = chat) do
    case chat_plan(chat) do
      {:ok, %{repo: repo, head: head, source: source}} -> already_merged?(repo, head, source)
      {:error, _reason} -> false
    end
  end

  # -- internals -------------------------------------------------------------------------------

  # What a merge needs, whatever authorised it: the repository, where it is going, what is being
  # merged, and the ref that keeps it reachable. `message` is filled in by the two functions that
  # make a commit and stays nil for the three that only read — a conflict check, "is this merged
  # already", and dealing with a closed conversation's branch all have an answer whether or not
  # anybody has written a commit message yet.
  defp ticket_plan(%Ticket{} = ticket, approved) do
    project = Tickets.project_of(ticket)
    repo = Projects.repo_path(project)

    with {:ok, source} <- resolve_approved(repo, approved),
         {:ok, head} <- default_head(repo, project) do
      {:ok,
       %{
         repo: repo,
         project: project,
         head: head,
         source: source,
         pin: "refs/forge/approved/#{ticket.number}",
         message: nil
       }}
    end
  end

  defp chat_plan(%Job{} = chat) do
    project = Projects.get!(chat.project_id)
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    with {:ok, source} <- Git.resolve(repo, "refs/heads/" <> branch),
         {:ok, head} <- default_head(repo, project) do
      {:ok,
       %{
         repo: repo,
         project: project,
         head: head,
         source: source,
         pin: "refs/forge/chat/#{chat.id}",
         message: nil
       }}
    end
  end

  # A ticket branch may be rewritten, so the commit a transition named can in principle be gone.
  # Refusing loudly is the point: merging the branch head instead would merge something nobody
  # approved.
  defp resolve_approved(repo, sha) do
    case Git.resolve(repo, sha) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _reason} -> {:error, {:approved_commit_gone, sha}}
    end
  end

  defp merge(%{repo: repo, project: project, head: head} = plan, tree, user) do
    with {:ok, sha} <- commit_tree(repo, tree, head, plan.message, user),
         :ok <- push(repo, project, sha) do
      {:ok, %{sha: sha, already: false}}
    end
  end

  # `merge-tree --write-tree` prints the merged tree, then — on a conflict, exit 1 — a block of
  # `<mode> <oid> <stage>\t<path>` lines, then its messages.
  defp merge_tree(repo, head, approved) do
    case Git.run(
           repo,
           ["merge-tree", "--write-tree", "--messages", {:data, head}, {:data, approved}],
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

  # The third producer of paths in this product, after `Forge.Git`'s `--numstat` and `ls-tree`:
  # these go into an event payload and into a ticket's stuck reason, so JSON and Postgres carry
  # them. Unlike those two, **this one is about reading and not about safety**: `merge_tree/3`
  # does not pass `core.quotePath=false`, so git has already quoted anything it cannot print and
  # what arrives is ASCII either way. What the pair does is put the name back in the form the
  # rest of the product uses — `résumé.md` rather than `"r\303\251sum\303\251.md"`, and the
  # escaped form kept only where there is no readable one.
  #
  # Unquoting first is what makes it a normalisation rather than a second encoding: without it
  # a name git had already quoted came out as `"\"caf\\351.md\""`, which is safe and is not
  # the file's.
  defp conflicted_paths(out) do
    out
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [_info, path] -> [path |> Git.unquote_path() |> Git.printable_path()]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  # **One parent, on purpose.** A ticket condenses into a single plain commit on the default
  # branch, so `git log --merges` shows nothing for it and the ticket's own run-by-run commits
  # stay on the ticket's ref rather than joining the default branch's ancestry. What keeps the
  # approved commit reachable instead is `refs/forge/approved/<n>` — or `refs/forge/chat/<id>` for
  # a conversation — which `attempt/2` writes before it merges (`docs/design/git-hosting.md`
  # § The merge).
  defp commit_tree(repo, tree, head, message, user) do
    # Every standalone argument is marked; `message` is not, because `-m` consumes the argument
    # after it whatever it begins with, and an agent's message may legitimately start with a dash
    # (`Forge.Git.run/3`).
    args = ["commit-tree", {:data, tree}, "-p", {:data, head}, "-m", message]

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

  # Nobody approved it, so the engine is the author as well as the committer. Stating the
  # committer alone left the *author* to the same passwd-entry fallback the rule above exists to
  # avoid, so the engine's own merge was the one merge that failed wherever there is no global
  # identity — a container, or a worker machine with a private HOME
  # (`docs/design/git-hosting.md` § The per-job token).
  defp author(nil),
    do: [{"GIT_AUTHOR_NAME", "forge"}, {"GIT_AUTHOR_EMAIL", "forge@localhost"}] ++ @committer

  defp author(%User{email: email}) do
    [{"GIT_AUTHOR_NAME", email}, {"GIT_AUTHOR_EMAIL", email}] ++ @committer
  end

  # The version the transition named, not the latest: a conversation that rewrote `commit-message`
  # between the approval and the entry action does not get to change what the commit says.
  defp ticket_commit_message(%Ticket{}, nil), do: {:error, :no_commit_message}

  defp ticket_commit_message(%Ticket{id: id}, version) do
    {:ticket, id}
    |> Artifacts.versions(Workflow.commit_message_artifact())
    |> Enum.find(&(&1.version == version))
    |> message_text()
  end

  # The latest, in the conversation's own document scope — the ticket's for a ticket chat, its own
  # otherwise, from the one definition of that rule (`Forge.Conversations.document_scope/1`).
  defp chat_commit_message(%Job{} = chat) do
    chat
    |> Conversations.document_scope()
    |> Artifacts.versions(Workflow.commit_message_artifact())
    |> List.last()
    |> message_text()
  end

  defp message_text(nil), do: {:error, :no_commit_message}

  defp message_text(version) do
    with {:ok, text} <- Artifacts.content(version),
         body = body_of(text),
         false <- String.trim(body) == "" do
      {:ok, body}
    else
      _blank_or_unreadable -> {:error, :no_commit_message}
    end
  end

  # Front matter is not part of the message. A `commit-message` carries none — the prompts ask for
  # a plain git message, and a state may not make it the document its outcome is read from
  # (`ForgeCore.Workflow.Validator`, § Validation) — but it is parsed like every other document,
  # so one written anyway would otherwise reach the commit as `---` lines.
  defp body_of(text) do
    case Document.parse(text) do
      {:ok, document} -> document.body
      # A version that does not parse is used as written rather than raising here. Reachable only
      # for one recorded with `parse: false`, since `Artifacts.put_version/5` parses a document
      # before it keeps one.
      {:error, _errors} -> text
    end
  end

  # FORGE_INTERNAL is what `pre-receive` accepts as authority over the default branch. It is set
  # here and nowhere else, and the git endpoint removes it from every child it spawns.
  defp push(repo, %Project{default_branch: default}, sha) do
    env = [{"FORGE_INTERNAL", "1"}]

    case Git.run(repo, ["push", "--quiet", ".", {:data, "#{sha}:refs/heads/#{default}"}],
           env: env
         ) do
      {:ok, _out} -> :ok
      {:error, reason} -> {:error, {:push_refused, reason}}
    end
  end
end
