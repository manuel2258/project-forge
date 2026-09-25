defmodule Forge.Jobs.Run do
  @moduledoc """
  One start of a job: where it ran, on which credential, and what it cost
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
    field :cost_usd, :decimal, default: Decimal.new(0)
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
