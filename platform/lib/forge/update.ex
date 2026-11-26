defmodule Forge.Update do
  @moduledoc """
  The git half of an update step: bringing a ticket's branch up to date with the project's default
  branch (`docs/design/workflow-grammar-v1.md` § Bringing the branch up to date). What it records,
  and where the ticket goes next, is `Forge.Engine`'s.

  From the ticket's head `H` and the default branch's head `D` it does one of four things:

    * `:current` — `D` is already in `H`. Nothing is written.
    * `:forwarded` — `H` is in `D`: the branch had nothing of its own, and moves to `D`.
    * `:merged` — `merge-tree` of `H` and `D` is clean: a merge commit, parents `H` then `D`, the
      platform as author and committer, and the branch moves to it.
    * `:conflict` — the merge conflicts. Nothing is written.

  **Every write is the platform's own push** (`Forge.Git.push_internal/3`) of the new head to
  `refs/heads/ticket/<n>` with a lease on `H`, never `update-ref`: `pre-receive` and the mirrors see
  it as they see a merge (`docs/design/git-hosting.md`), and a branch a developer's token moved since
  `H` was read is refused rather than overwritten.

  **A failed attempt is decided again once.** When a write fails and the branch is no longer at the
  head the attempt read, the whole decision is made again from the new head; when that fails and the
  branch moved a second time, it is `{:error, :branch_moving}` — the same rule `Forge.Merge` has for
  the default branch (`docs/design/git-hosting.md` § Where it runs, and what a conflict does). A
  failure with the branch unmoved is returned as it is: a second attempt would meet it again.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Events.Event
  alias Forge.{Git, Merge, Projects, Repo, Tickets}
  alias Forge.Tickets.Ticket

  # How many merges an update step records as brought in; the rest are counted (`:more`).
  @shown 10

  @typedoc """
  What a run learned. `head` and `to` are the ticket's head before and after, `default` the default
  branch's head it merged or met, `retried` whether the first attempt was decided again,
  `merges` the merges it brought in (newest first, at most #{@shown}) and `more` how many were left out.
  """
  @type facts :: %{
          head: String.t(),
          default: String.t(),
          to: String.t(),
          retried: boolean(),
          merges: [map()],
          more: non_neg_integer()
        }

  @type result ::
          {:current | :forwarded | :merged, facts()}
          | {:conflict, %{paths: [String.t()], head: String.t(), default: String.t()}, boolean()}
          | {:error, term()}

  @doc """
  Brings `ticket`'s branch up to date, or says why it could not.

  `{:conflict, facts, retried}` carries the paths the merge conflicted in.
  """
  @spec run(Ticket.t()) :: result()
  def run(%Ticket{} = ticket) do
    project = Tickets.project_of(ticket)
    repo = Projects.repo_path(project)
    plan = %{repo: repo, project: project, ref: "refs/heads/" <> ticket.branch}

    case attempt(plan) do
      {:error, {:failed, head, reason}} ->
        case Git.resolve(repo, plan.ref) do
          {:ok, moved} when moved != head -> retry(plan)
          _unmoved -> {:error, reason}
        end

      other ->
        other
    end
  end

  # The one more attempt, from the head the branch has now. Whatever it returns is final, but for
  # one thing: it failing with the branch moved *again* is the sign someone is pushing to it.
  defp retry(plan) do
    case attempt(plan) do
      {:error, {:failed, head, reason}} ->
        case Git.resolve(plan.repo, plan.ref) do
          {:ok, again} when again != head -> {:error, :branch_moving}
          _unmoved -> {:error, reason}
        end

      {:conflict, facts, _retried} ->
        {:conflict, facts, true}

      {:error, _reason} = error ->
        error

      {kind, facts} ->
        {kind, %{facts | retried: true}}
    end
  end

  # One attempt from the heads as they are now. `{:error, {:failed, head, reason}}` is a failure to
  # write, with the head the attempt read, so the caller can tell whether the branch moved under it.
  defp attempt(%{repo: repo, project: project, ref: ref}) do
    with {:ok, head} <- Git.resolve(repo, ref),
         {:ok, default} <- Git.resolve(repo, "refs/heads/" <> project.default_branch) do
      decide(%{repo: repo, project: project, ref: ref}, head, default)
    end
  end

  defp decide(plan, head, default) do
    %{repo: repo} = plan

    cond do
      Git.ancestor?(repo, default, head) ->
        {:current, facts(head, default, head, [], 0)}

      Git.ancestor?(repo, head, default) ->
        write(plan, head, default, default, :forwarded)

      true ->
        case Merge.merge_tree(repo, head, default) do
          {:ok, tree} -> merge_commit(plan, head, default, tree)
          {:conflict, paths} -> {:conflict, %{paths: paths, head: head, default: default}, false}
          {:error, reason} -> {:error, {:failed, head, reason}}
        end
    end
  end

  defp merge_commit(%{repo: repo, project: project, ref: ref} = plan, head, default, tree) do
    message =
      "Merge #{project.default_branch} into #{String.replace_prefix(ref, "refs/heads/", "")}\n"

    case Merge.commit_tree(repo, tree, [head, default], message, nil) do
      {:ok, sha} -> write(plan, head, default, sha, :merged)
      {:error, reason} -> {:error, {:failed, head, reason}}
    end
  end

  # The lease is the push's own check that the branch is still at `head`, and what `Forge.GitTest`
  # pins. What is pushed is always a descendant of `head`, so without the lease the push is a plain
  # fast-forward, which a branch that moved to anything else refuses for being behind. The lease
  # adds a refusal for a branch that moved to a descendant of `head`; a test could tell it apart
  # (`retried` and `from` in the event differ), and none does, so this is not claimed as an
  # equivalent mutant. (A lease is also a force, which the descendant this pushes never needs.)
  defp write(%{repo: repo, ref: ref} = plan, head, default, new, kind) do
    case Git.push_internal(repo, "#{new}:#{ref}", lease: {ref, head}) do
      :ok ->
        {merges, more} = brought_in(plan, head, default)
        {kind, facts(head, default, new, merges, more)}

      {:error, reason} ->
        {:error, {:failed, head, reason}}
    end
  end

  defp facts(head, default, to, merges, more),
    do: %{head: head, default: default, to: to, retried: false, merges: merges, more: more}

  # What the default branch gained since the ticket's branch last met it: its first-parent commits
  # from the merge base to `default`, newest first, each said by the ticket or conversation whose
  # merge it was where the platform recorded one, and by its subject where it did not. Never fails
  # a visit: a log that cannot be read is no merges listed.
  defp brought_in(%{repo: repo, project: project}, head, default) do
    with {:ok, base} <- Git.merge_base(repo, head, default),
         {:ok, log} <- Git.log(repo, base, default, first_parent: true) do
      {attribute(project.id, Enum.take(log, @shown)), max(length(log) - @shown, 0)}
    else
      _unreadable -> {[], 0}
    end
  end

  defp attribute(project_id, commits) do
    shas = Enum.map(commits, & &1.sha)
    tickets = merged_tickets(project_id, shas)
    chats = merged_chats(project_id, shas)

    Enum.map(commits, fn commit ->
      %{"sha" => commit.sha, "subject" => commit.subject}
      |> put_source(tickets[commit.sha], chats[commit.sha])
    end)
  end

  defp put_source(merge, number, _chat) when is_integer(number),
    do: Map.put(merge, "ticket", number)

  defp put_source(merge, _number, chat) when is_binary(chat), do: Map.put(merge, "chat", chat)
  defp put_source(merge, _none, _none_either), do: merge

  # A ticket's merge logs `ticket.merged` with the commit it landed, and a conversation's
  # `chat.merged` (`Forge.Operator.merge_chat/2`); older conversation merges logged nothing and are
  # drawn by their subject. **Only this project's**: two projects whose repositories share history
  # hold the same commit, and a number or a conversation of the other would be drawn as this one's.
  defp merged_tickets(project_id, shas) do
    from(e in Event,
      join: t in Ticket,
      on: t.id == e.ticket_id,
      where: t.project_id == ^project_id,
      where: e.type == "ticket.merged" and fragment("?->>'sha'", e.payload) in ^shas,
      where: fragment("coalesce((?->>'already')::boolean, false)", e.payload) == false,
      select: {fragment("?->>'sha'", e.payload), t.number}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp merged_chats(project_id, shas) do
    from(e in Event,
      where: e.project_id == ^project_id,
      where: e.type == "chat.merged" and fragment("?->>'sha'", e.payload) in ^shas,
      select: {fragment("?->>'sha'", e.payload), fragment("?->>'chat'", e.payload)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # -- what a visit records, and how it reads ---------------------------------------------------

  @doc "The default branch's head a result merged or met, or nil for a failure."
  @spec default_of(result()) :: String.t() | nil
  def default_of({:conflict, %{default: default}, _retried}), do: default
  def default_of({:error, _reason}), do: nil
  def default_of({_kind, %{default: default}}), do: default

  @doc """
  The payload of `ticket.branch_updated` for a result, less what the engine adds (the state, the
  default branch, the re-pin and where the ticket went): the result, the head before and after, the
  default branch's head, and the paths or merges or reason.
  """
  @spec payload(result()) :: map()
  def payload({:conflict, facts, retried}) do
    %{
      "result" => "conflicted",
      "from" => facts.head,
      "to" => facts.head,
      "default" => facts.default,
      "paths" => facts.paths,
      "retried" => retried
    }
  end

  def payload({:error, reason}), do: %{"result" => "failed", "reason" => failed_reason(reason)}

  def payload({kind, facts}) do
    %{
      "result" => Atom.to_string(kind),
      "from" => facts.head,
      "to" => facts.to,
      "default" => facts.default,
      "merges" => facts.merges,
      "more" => facts.more,
      "retried" => facts.retried
    }
  end

  @doc "Why a visit failed, in words."
  @spec failed_reason(term()) :: String.t()
  def failed_reason(:branch_moving),
    do:
      "the branch was pushed to twice while it was being brought up to date; " <>
        "someone is pushing to it by hand"

  def failed_reason(:job_live), do: "a job of this ticket is still running"
  def failed_reason(other), do: "git refused it: " <> cut(inspect(other), 300)

  @doc "What a ticket that a failed visit stuck says."
  @spec failed_words(result(), String.t()) :: String.t()
  def failed_words({:error, reason}, default),
    do: "bringing the branch up to date with #{default} failed: #{failed_reason(reason)}"

  @doc "What a ticket stuck by a conflict with nowhere to go says: the first paths, then a count."
  @spec conflict_words([String.t()], String.t()) :: String.t()
  def conflict_words(paths, default) do
    {shown, left} = Enum.split(paths, 3)
    listed = Enum.map_join(shown, ", ", &cut(&1, 100))
    more = if left == [], do: "", else: " and #{length(left)} more"

    "bringing the branch up to date with #{default} conflicted in #{listed}#{more}"
  end

  @doc "Why a re-pin was skipped, from what stopped the workflow being read, in words."
  @spec skip_words(term()) :: String.t()
  def skip_words({:ticket_type_gone, _name, path}),
    do: "the workflow file #{cut(to_string(path), 100)} is gone there"

  def skip_words([%ForgeCore.Error{} = first | rest]) do
    more = if rest == [], do: "", else: " (and #{length(rest)} more)"

    "the workflow there does not validate: #{cut(first.path, 80)} #{cut(first.message, 160)}#{more}"
  end

  def skip_words(other), do: "the workflow there could not be read: " <> cut(inspect(other), 160)

  @doc """
  The sentence a visit reads as, from its `ticket.branch_updated` payload: what it did to the
  branch, without the re-pin (`repin_said/1`). Every value is drawn from the payload and cut, since
  a path and a subject are a contributor's.
  """
  @spec said(map()) :: String.t()
  def said(%{"result" => "current"} = p),
    do: "already up to date with #{p["default_branch"]} at #{short(p["default"])}"

  def said(%{"result" => "forwarded"} = p),
    do: "moved forward to #{short(p["to"])}" <> bringing(p)

  def said(%{"result" => "merged"} = p),
    do: "merged #{p["default_branch"]} at #{short(p["default"])}" <> bringing(p)

  def said(%{"result" => "conflicted"} = p) do
    paths = p["paths"] || []
    first = paths |> List.first() |> cut(100)
    more = if length(paths) > 1, do: " and #{length(paths) - 1} more", else: ""

    went =
      cond do
        p["went"] -> "; went to #{p["went"]}"
        p["held"] -> "; waits for release"
        true -> "; stuck"
      end

    "conflicted with #{p["default_branch"]} in #{first}#{more}#{went}"
  end

  def said(%{"result" => "failed"} = p),
    do: "could not bring the branch up to date: #{cut(p["reason"], 300)}"

  def said(_other), do: "brought the branch up to date"

  defp bringing(%{"merges" => merges} = p) when is_list(merges) do
    count = length(merges) + (p["more"] || 0)

    cond do
      count == 0 -> ""
      count == 1 -> ", bringing in 1 merge"
      true -> ", bringing in #{count} merges"
    end
  end

  defp bringing(_none), do: ""

  # The skip codes `Forge.Engine` records when it cannot re-pin that are the type's file's own
  # refusal (gone, does not validate, cannot be read): the ones a person's Re-pin would meet too. The
  # other codes (`no_state`, `not_an_update_step`) are about the step, which a hand re-pin does not
  # ask. **A code the engine adds is not a file's reason until it is listed here.**
  @file_refusals ~w(type_gone invalid unreadable)

  @doc "Whether a skipped re-pin's code is the type's file's own refusal, which a hand re-pin meets too."
  @spec file_refusal?(term()) :: boolean()
  def file_refusal?(code), do: code in @file_refusals

  @doc "What became of the pin, in words: `re-pinned from a to b`, or `not re-pinned: <why>`, or nil."
  @spec repin_said(map()) :: String.t() | nil
  def repin_said(%{"repin" => %{"skipped" => _code, "reason" => reason}}),
    do: "not re-pinned: #{cut(reason, 300)}"

  def repin_said(%{"repin" => %{"from" => from, "to" => to}}) when is_binary(from),
    do: "re-pinned from #{short(from)} to #{short(to)}"

  def repin_said(%{"repin" => %{"to" => to}}), do: "re-pinned to #{short(to)}"
  def repin_said(_none), do: nil

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short(_none), do: "?"

  defp cut(text, most) when is_binary(text), do: String.slice(text, 0, most)
  defp cut(_none, _most), do: ""

  # -- what the ticket page reads ---------------------------------------------------------------

  @doc "A ticket's update-step visits, oldest first, as `{seq, payload}` (`ticket.branch_updated`)."
  @spec visits(String.t()) :: [{pos_integer(), map()}]
  def visits(ticket_id) do
    Repo.all(
      from e in Event,
        where: e.ticket_id == ^ticket_id and e.type == "ticket.branch_updated",
        order_by: e.seq,
        select: {e.seq, e.payload}
    )
  end

  @doc "The titles of the project's tickets numbered `numbers`, by number."
  @spec titles(String.t(), [integer()]) :: %{integer() => String.t()}
  def titles(_project_id, []), do: %{}

  def titles(project_id, numbers) do
    from(t in Ticket,
      where: t.project_id == ^project_id and t.number in ^numbers,
      select: {t.number, t.title}
    )
    |> Repo.all()
    |> Map.new()
  end
end
