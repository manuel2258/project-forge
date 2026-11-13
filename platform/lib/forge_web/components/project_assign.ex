defmodule ForgeWeb.ProjectAssign do
  @moduledoc """
  The projects a machine, a template or an inference credential serves, and the control that
  changes them (`docs/design/ui.md` § Machines, § Templates and credentials, § Account settings):
  a chip per project with its `×`, and a select of **the projects not yet assigned** with an
  *Assign* button.

  One control in all three places (UX pass, D5). Each used to render every project the viewer is
  in, so the select often opened on one already assigned and *Assign* changed nothing; and each
  drew its chip and its button differently.

  The select starts on a disabled *add a project…*, so nothing is assigned by a tap that chose
  nothing, and the form is not drawn once every project is assigned. What may be assigned is still
  decided where it is written — `Workers.assign/3`, `Provisioning.assign/3`,
  `Credentials.assign/3` — whatever the select offered.

  Styles are in `assets/css/areas/machines.css` under `project-assign`.
  """

  use Phoenix.Component

  import ForgeWeb.CoreComponents, only: [button: 1]

  @doc """
  The projects of `projects` that are not in `assigned`, by id and in `projects`' order: what the
  select may offer.
  """
  @spec unassigned([%{id: term()}], [%{id: term()}]) :: [%{id: term()}]
  def unassigned(projects, assigned) do
    taken = MapSet.new(assigned, & &1.id)
    Enum.reject(projects, &MapSet.member?(taken, &1.id))
  end

  attr :id, :string, required: true
  attr :assigned, :list, required: true, doc: "the projects assigned now"
  attr :projects, :list, required: true, doc: "every project the viewer may assign"
  attr :assign, :string, required: true, doc: "the event the form submits"
  attr :unassign, :string, required: true, doc: "the event a chip's × sends"
  attr :values, :list, required: true, doc: "`{name, value}` the events carry beside `project`"
  attr :remove, :string, required: true, doc: "the ×'s label, before the project's name"
  attr :label, :string, default: nil, doc: "the word before the chips: `serves`, `Funds`"
  attr :none, :string, required: true, doc: "what is said when nothing is assigned"
  attr :none_tone, :string, default: nil, values: [nil, "warning", "danger"]
  attr :can_add, :boolean, default: true, doc: "false hides the form: a destroyed machine"

  def project_assign(assigns) do
    assigns = assign(assigns, :offered, unassigned(assigns.projects, assigns.assigned))

    ~H"""
    <div id={@id} class="project-assign">
      <div class="project-assign-chips">
        <span :if={@label} class="project-assign-label">{@label}</span>
        <span :for={project <- @assigned} class="project-chip">
          {project.name}
          <button
            type="button"
            phx-click={@unassign}
            phx-value-project={project.id}
            {phx_values(@values)}
            class="project-chip-remove min-h-[46px] min-w-[46px]"
            aria-label={"#{@remove} #{project.name}"}
          >
            ×
          </button>
        </span>
        <span
          :if={@assigned == []}
          class={["project-assign-none", @none_tone && "text-#{@none_tone}"]}
        >
          {@none}
        </span>
      </div>
      <form :if={@can_add and @offered != []} phx-submit={@assign} class="project-assign-form">
        <input :for={{name, value} <- @values} type="hidden" name={name} value={value} />
        <select
          name="project"
          aria-label="Project"
          class="machine-select project-assign-select h-[46px]"
          required
        >
          <option value="" disabled selected>add a project…</option>
          <option :for={project <- @offered} value={project.id}>{project.name}</option>
        </select>
        <.button type="submit" variant="secondary" size="md">Assign</.button>
      </form>
    </div>
    """
  end

  defp phx_values(values),
    do: Map.new(values, fn {name, value} -> {"phx-value-#{name}", value} end)
end
