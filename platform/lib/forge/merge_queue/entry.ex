defmodule Forge.MergeQueue.Entry do
  @moduledoc """
  One ticket's place in its project's merge queue (`docs/design/workflow-grammar-v1.md` § The merge
  queue). A ticket has a row exactly while it is queued; the events are the history.

  `from_state`, `to_state` and `edge_outcome` name the edge the ticket is queued for, so the runner
  can take it by `ForgeCore.Engine.choose/4`; `outcome` is the job's outcome behind it, if any; `changeset_*` and `commit_message_version` are what was
  current when it was approved, which is what the merge uses — until an integration puts the row
  back in the line, when they become the integrated changeset and the latest `commit-message`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "merge_queue_entries" do
    field :position, :integer, read_after_writes: true
    field :status, Ecto.Enum, values: [:waiting, :merging, :integrating], default: :waiting
    field :from_state, :string
    field :to_state, :string
    field :outcome, :string
    field :edge_outcome, :string
    field :changeset_sha, :string
    field :changeset_version, :integer
    field :commit_message_version, :integer
    field :approval_ids, {:array, :binary_id}, default: []
    field :entered_by, :map, default: %{}
    field :comment, :string

    belongs_to :project, Forge.Projects.Project
    belongs_to :ticket, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
