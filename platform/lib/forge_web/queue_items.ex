defmodule ForgeWeb.QueueItems do
  @moduledoc """
  What the queue says an item is, in one place: the grouping of a document version's questions
  into one item and the words a row's kicker carries (*approval*, *2 blocking questions*, *review
  ready*, *stuck*, *conversation*). The queue page draws its items with them, and the rows of
  **On hold** and the project's Tickets list name what waits on a held ticket in the same words
  (`docs/design/ui.md` § The end of the pass, and *All*), so there is one copy of each.
  """

  @doc """
  Items grouped into the interruptions a person decides: one job, stopped, against one artifact
  version, carrying N questions, is one item (`:questions`). Everything else is already one
  interruption on its own. A caller passes an assumption only when a blocking question shares its
  version, so every group holds at least one of those. Oldest first.
  """
  @spec group([map()]) :: [map()]
  def group(items) do
    {questions, rest} = Enum.split_with(items, &(&1.kind in [:question, :assumption]))

    questions
    |> Enum.group_by(& &1.question.artifact_version_id)
    |> Enum.map(fn {_version_id, group} ->
      first = hd(group)

      %{
        kind: :questions,
        ticket: first.ticket,
        project: first.project,
        # When it started waiting, which the blocking questions say. Taking the assumptions too is
        # an equivalent mutant as documents are recorded: a version's questions share one insert.
        since:
          group
          |> Enum.filter(&(&1.kind == :question))
          |> Enum.map(& &1.since)
          |> Enum.min(DateTime),
        questions: Enum.map(group, & &1.question),
        version: first.question.artifact_version,
        detail: %{}
      }
    end)
    |> Enum.concat(rest)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  @doc """
  The item's kind alone, which a row's kicker carries: where it is — the document and its
  version, the transition — is the row's latest line, said once (UX pass, A24). Counted as
  blocking: an assumption in the same card is optional and waits on nobody.
  """
  @spec kind(map()) :: String.t()
  def kind(%{kind: :questions, questions: questions}) do
    blocking = Enum.count(questions, & &1.blocking)
    "#{blocking} blocking #{noun(blocking, "question")}"
  end

  def kind(%{kind: :chat}), do: "conversation"
  def kind(%{kind: :approval}), do: "approval"
  def kind(%{kind: :stuck}), do: "stuck"
  def kind(%{kind: :review}), do: "review ready"
  def kind(%{kind: :accounts}), do: "accounts"

  def kind(%{kind: :schedule, detail: %{problem_kind: :switched_off}}),
    do: "schedule switched off"

  def kind(%{kind: :schedule}), do: "schedule failed"

  @doc """
  What waits on a ticket, in the kicker's words, joined by ` · `: its items grouped as the queue
  groups them, oldest first. Empty for none.
  """
  @spec waits([map()]) :: String.t()
  def waits(items) do
    items |> group() |> Enum.map_join(" · ", &kind/1)
  end

  @doc "A noun, pluralised unless the count is one."
  @spec noun(integer(), String.t()) :: String.t()
  def noun(1, word), do: word
  def noun(_count, word), do: word <> "s"
end
