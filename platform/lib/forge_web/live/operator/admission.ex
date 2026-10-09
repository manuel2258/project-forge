defmodule ForgeWeb.Operator.Admission do
  @moduledoc """
  Why a project cannot take a ticket, in words.

  `Forge.Tickets.types/2` answers the question; this renders its answer. Two surfaces ask —
  the ticket form before anything is typed, and the project page — and they said it differently
  until the sentences were brought here. An operator who meets the same condition on two pages
  should read the same sentence.
  """

  alias ForgeCore.Error

  # The refusals that are about which workflow a ticket would run, as distinct from the workflow
  # not parsing: what the API answers with a code of its own and every surface says in one
  # sentence. One list, so the API, the project page and the ticket's actions cannot disagree
  # about which of them they know.
  @type_reasons [
    :both_workflow_forms,
    :no_ticket_type_in,
    :no_ticket_types,
    :ticket_type_required,
    :unknown_ticket_type,
    :invalid_ticket_type
  ]

  @doc "Whether `reason` is one of the refusals about a ticket's type, for a guard."
  defguard type_reason(reason)
           when is_tuple(reason) and tuple_size(reason) >= 2 and
                  elem(reason, 0) in @type_reasons

  @doc "Whether a workflow came back for a type of `Tickets.types/2`."
  @spec ready?(term()) :: boolean()
  def ready?({:ok, _workflow}), do: true
  def ready?(_other), do: false

  @doc """
  The reason, as a clause that completes "this project cannot take a ticket: …".

  A repository whose default branch does not exist fails before the workflow is looked for —
  `{:unknown_ref, branch}`, not a missing file — because there is no commit to look in.

  That used to be the state a project was in the moment it was created, and this note used to say
  so. It is not any more: `Projects.register/1` gives the default branch an empty root commit, so
  a freshly created project has a branch and no `.forge/workflow.yml`, and the sentence an
  operator arriving from `/projects/new` actually meets is `{:no_workflow_file, path}`.
  `{:unknown_ref, _}` is now reached only when the branch is deleted from the repository
  afterwards, which nothing in the product does.

  Both sentences mention `.forge/workflow.yml`, which is why asserting on that substring alone
  cannot tell them apart — the tests assert the whole sentence.
  """
  @spec explain(term()) :: String.t()
  def explain({:unknown_ref, branch}),
    do: "nothing has been pushed to its #{branch} branch yet, so there is no .forge/workflow.yml"

  def explain({:no_workflow_file, path}), do: "there is no #{path} on its default branch"

  # Ticket types (`docs/design/ticket-types.md`). The first is the repository's fault and the rest
  # are the request's, but each still completes the same sentence.
  def explain({:both_workflow_forms, single, dir}),
    do: "it has both #{single} and #{dir}, and nothing says which a ticket runs"

  def explain({:no_ticket_types, name}),
    do: "it has no ticket types, only one workflow, so it has no type #{name}"

  def explain({:ticket_type_required, names}),
    do: "it has more than one ticket type, so one must be chosen: #{Enum.join(names, ", ")}"

  def explain({:unknown_ticket_type, name, names}),
    do: "it has no ticket type #{name}; it has #{Enum.join(names, ", ")}"

  def explain({:invalid_ticket_type, _value}), do: "a ticket type is a name, like bug"

  def explain({:no_ticket_type_in, dir, not_types}) do
    reasons = Enum.map_join(not_types, "; ", &"#{&1.path} is #{&1.why}")
    "there is no .forge/workflow.yml, and nothing in #{dir} is a ticket type: #{reasons}"
  end

  def explain(errors) when is_list(errors),
    do: "its workflow does not parse: " <> Error.format(errors)

  def explain(reason), do: inspect(reason)
end
