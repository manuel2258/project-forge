defmodule Forge.Milestones.Milestone do
  @moduledoc """
  A named goal of one project, with an order among the project's milestones
  (`docs/design/ui.md` § Milestones). It has a name and an optional description and **no date**.

  Never deleted: closing sets `closed_at`, and a closed milestone keeps its name, which stays
  taken. At most one open milestone of a project is `current`, which the database enforces with a
  partial unique index beside the code that unmarks the old one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @name_limit 80
  @description_limit 2_000

  @doc "The longest a milestone's name may be, in characters."
  @spec name_limit() :: pos_integer()
  def name_limit, do: @name_limit

  @doc "The longest a milestone's description may be, in characters."
  @spec description_limit() :: pos_integer()
  def description_limit, do: @description_limit

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "milestones" do
    field :name, :string
    field :description, :string
    field :position, :integer, default: 0
    field :current, :boolean, default: false
    field :closed_at, :utc_datetime

    belongs_to :project, Forge.Projects.Project

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Whether the milestone is open: not closed."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{closed_at: nil}), do: true
  def open?(%__MODULE__{}), do: false

  @doc "A name and a description, trimmed, the name required and both limited."
  def text_changeset(milestone, attrs) do
    milestone
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &trim/1)
    |> update_change(:description, &blank_to_nil/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @name_limit)
    |> validate_length(:description, max: @description_limit)
    |> unique_constraint(:name, name: :milestones_project_id_name_index)
  end

  @doc "A new milestone: its text, its project and its place in the project's order."
  def create_changeset(milestone, attrs) do
    milestone
    |> cast(attrs, [:project_id, :position])
    |> validate_required([:project_id])
    |> text_changeset(attrs)
    |> foreign_key_constraint(:project_id)
  end

  @doc "Marking and unmarking as current, and nothing else."
  def current_changeset(milestone, current) when is_boolean(current) do
    milestone
    |> change(current: current)
    |> unique_constraint(:project_id, name: :milestones_one_current_per_project)
    |> check_constraint(:current, name: :milestones_current_is_open)
  end

  @doc "Closing and reopening: `closed_at`, and un-marking as current when closing."
  def closing_changeset(milestone, closed_at) do
    milestone
    |> change(closed_at: closed_at, current: if(closed_at, do: false, else: milestone.current))
  end

  @doc "Where the milestone is in its project's order, and nothing else."
  def position_changeset(milestone, position), do: change(milestone, position: position)

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(other), do: other

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(other), do: other
end
