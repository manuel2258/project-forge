defmodule Forge.JobsResultTest do
  @moduledoc """
  What a finished job's `job.finished` event keeps of why it failed. Two refinements failed in
  production with the reason `invalid documents: refinement.md` and nothing else: the documents
  were dropped and the machines destroyed, so why they did not parse had to be rebuilt from the
  transcripts.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.{Events, Jobs}
  alias ForgeCore.Error
  alias ForgeCore.Job.Result

  test "job.finished carries each invalid document's errors as text" do
    ticket = ticket_fixture()
    job = job_fixture(%{ticket: ticket, status: :running})

    result = %Result{
      status: :finished,
      outcome: :error,
      reason: "invalid documents: refinement.md (…)",
      invalid: %{
        "refinement.md" => [
          Error.new("question[2].options", "must be a non-empty list of strings"),
          Error.new("question[2].default", "must be a string")
        ]
      }
    }

    {:ok, _job} = Jobs.complete(job.id, result)

    assert [event] = Enum.filter(Events.for_job(job.id), &(&1.type == "job.finished"))

    assert event.payload["invalid"] == %{
             "refinement.md" =>
               "question[2].options: must be a non-empty list of strings\n" <>
                 "question[2].default: must be a string"
           }
  end

  # What arrives over the channel has already been through `Result.to_map/1`, which renders the
  # errors as text; the payload keeps it as it came.
  test "errors that arrived as text are kept as they came" do
    ticket = ticket_fixture()
    job = job_fixture(%{ticket: ticket, status: :running})

    {:ok, _job} =
      Jobs.complete(job.id, %Result{
        status: :finished,
        outcome: :error,
        invalid: %{"plan.md" => "question[0]: invalid YAML"}
      })

    assert [event] = Enum.filter(Events.for_job(job.id), &(&1.type == "job.finished"))
    assert event.payload["invalid"] == %{"plan.md" => "question[0]: invalid YAML"}
  end
end
