defmodule Forge.Jobs.Run do
  @moduledoc """
  One start of a job: where it ran, on which credential, and what it used
  (`docs/design/credentials.md` § Spend).

  Written by `Forge.Jobs.Runs` and nowhere else. A run is opened in the transaction that marks its
  job running and closed when the job reports, stops, or is found to have lost its run.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "job_runs" do
    belongs_to :job, Forge.Jobs.Job
    belongs_to :credential, Forge.Credentials.Credential
    belongs_to :worker, Forge.Workers.Worker
    field :started_at, :utc_datetime
    # Weighted tokens (`ForgeCore.Usage`), the tokens by kind behind them (nil where `converted`),
    # and Claude Code's own dollar figure, kept for information and read by no cap and no pick.
    field :usage, :integer, default: 0
    field :tokens, :map
    field :claude_cost_usd, :decimal
    field :converted, :boolean, default: false
    # Copied from the credential's kind when the run opens: a live exclusive run is a hold on its
    # credential, and the database lets there be one (`Forge.Credentials` § Holding).
    field :exclusive, :boolean, default: false
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
