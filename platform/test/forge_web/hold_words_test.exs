defmodule ForgeWeb.HoldWordsTest do
  @moduledoc """
  The words a refused hold, release, stop, title, milestone or move is said in, on the page
  (`ForgeWeb.Operator.Actions.describe/1`) and over the API (`ForgeWeb.Api.FallbackController`):
  *on hold*, *hold* and *release*, never *paused*, which is the spend and capacity pauses' word.
  """

  use ForgeWeb.ConnCase, async: true

  alias ForgeWeb.Api.FallbackController
  alias ForgeWeb.Operator.Actions

  @reasons [
    {:already_on_hold, 409},
    {:not_on_hold, 409},
    {{:not_holdable, :done}, 409},
    {{:not_releasable, :cancelled}, 409},
    {:nothing_running, 409},
    {{:no_state, "refining"}, 422},
    {:branch_moved, 409},
    {:changed, 409},
    {:release_title, 422},
    {:blank, 422},
    {{:not_open, :cancelled}, 409},
    {:moved, 409},
    {:not_in_order, 422},
    {:milestone, 422},
    {:closed, 409},
    {:already_closed, 409},
    {:not_closed, 409},
    {:start_or_hold, 422}
  ]

  test "every refusal has a sentence on the page, and none says paused" do
    for {reason, _status} <- @reasons do
      words = Actions.describe(reason)

      assert is_binary(words) and words != "something went wrong; see the server log",
             inspect(reason)

      refute words =~ ~r/paused|parked/i, inspect(reason)
    end

    assert Actions.describe(:not_found) =~ "does not exist"

    assert Actions.describe({:no_workflow_file, ".forge/workflow.yml"}) =~
             ".forge/workflow.yml is not on the default branch"
  end

  test "every refusal has a status over the API, none of them a 500", %{conn: conn} do
    for {reason, status} <- @reasons do
      conn = FallbackController.call(conn, {:error, reason})
      assert conn.status == status, inspect(reason)
      refute conn.resp_body =~ "internal"
    end
  end

  test "a changeset's errors are said with their limit" do
    changeset =
      %Forge.Milestones.Milestone{}
      |> Forge.Milestones.Milestone.create_changeset(%{
        project_id: Ecto.UUID.generate(),
        name: String.duplicate("n", 81)
      })

    assert Actions.describe(changeset) =~ "name should be at most 80 character"
  end

  test "a milestone is open until it has a closing time" do
    assert Forge.Milestones.Milestone.open?(%Forge.Milestones.Milestone{})

    refute Forge.Milestones.Milestone.open?(%Forge.Milestones.Milestone{
             closed_at: DateTime.utc_now()
           })

    assert Forge.Milestones.Milestone.description_limit() == 2_000
  end
end
