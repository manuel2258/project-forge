defmodule ForgeWeb.Operator.Admission do
  @moduledoc """
  Why a project cannot take a ticket, in words.

  `Forge.Tickets.admissible/1` answers the question; this renders its answer. Two surfaces ask —
  the ticket form before anything is typed, and the project page — and they said it differently
  until the sentences were brought here. An operator who meets the same condition on two pages
  should read the same sentence.
  """

  alias ForgeCore.Error

  @doc "Whether `Tickets.admissible/1` said yes."
  @spec ready?(term()) :: boolean()
  def ready?({:ok, _workflow}), do: true
  def ready?(_other), do: false

  @doc """
  The reason, as a clause that completes "this project cannot take a ticket: …".

  An empty repository fails before the workflow is looked for — `{:unknown_ref, branch}`, not a
  missing file — and that is the state a project is in the moment it is created, so it is the
  sentence an operator arriving from `/projects/new` is most likely to meet.
  """
  @spec explain(term()) :: String.t()
  def explain({:unknown_ref, branch}),
    do: "nothing has been pushed to its #{branch} branch yet, so there is no .forge/workflow.yml"

  def explain({:no_workflow_file, path}), do: "there is no #{path} on its default branch"

  def explain(errors) when is_list(errors),
    do: "its workflow does not parse: " <> Error.format(errors)

  def explain(reason), do: inspect(reason)
end
