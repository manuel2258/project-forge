defmodule Mix.Tasks.Forge.Chat do
  @shortdoc "Opens a conversation, or talks to one"

  @moduledoc """
  Conversations from the terminal.

      mix forge.chat open PROJECT "what is this repository?"
      mix forge.chat open PROJECT --ticket 4 "why did refining fail?"
      mix forge.chat show ID
      mix forge.chat say ID "try it with the other backend" --node forge@host
      mix forge.chat close ID --node forge@host

  ## Why `say` and `close` want `--node`

  Reaching a running conversation means reaching its worker, and a worker is reached through the
  registry of the node holding the connection — the one serving the platform. A Mix task is a
  different node with an empty registry, so a message sent from here is written to the log and
  delivered to nobody: the conversation simply never hears it.

  With `--node` the work happens on the live node through one call, and this process is only a
  driver. Without it, a message to a *running* conversation is refused rather than quietly lost.
  `open` and `show` need no node: one writes rows and creates a branch, the other reads.

  The platform must be running under that name and cookie:

      elixir --sname forge --cookie forge-e2e -S mix phx.server
  """

  use Mix.Task

  alias Forge.{CLI, Conversations, Projects, Tickets}

  @impl Mix.Task
  def run(args) do
    # Not `@requirements ["app.start"]`: that boots the whole platform, scheduler included, so a
    # task run beside the real node competes with it for work and recovers it out from under
    # itself — putting every live conversation to sleep. `CLI.boot/0` is what the other eighteen
    # `forge.*` tasks use, and turns the scheduler off before starting.
    CLI.boot()

    {opts, rest} = OptionParser.parse!(args, strict: [ticket: :integer, node: :string])
    dispatch(rest, opts)
  end

  defp dispatch(["open", name | words], opts) do
    project = Projects.by_name(name) || Mix.raise("no project named #{name}")
    ticket = opts[:ticket] && Tickets.get_by_number!(project, opts[:ticket])
    text = said(words)

    case Conversations.open(project, text, ticket: ticket) do
      {:ok, chat} ->
        Mix.shell().info("opened #{chat.id} on #{project.name}#{about(ticket)}")
        Mix.shell().info("branch chat/#{chat.id}; it is queued and will start on a free worker")

      {:error, reason} ->
        Mix.raise("could not open: #{inspect(reason)}")
    end
  end

  defp dispatch(["say", id | words], opts) do
    text = said(words)

    case on_node(opts, Conversations, :send, [Conversations.get!(id), text]) do
      {:ok, _event} -> Mix.shell().info("sent")
      {:error, reason} -> Mix.raise("could not send: #{inspect(reason)}")
    end
  end

  defp dispatch(["close", id], opts) do
    :ok = on_node(opts, Conversations, :close, [Conversations.get!(id), "closed"])
    Mix.shell().info("closing #{id}; the last turn finishes first")
  end

  defp dispatch(["show", id], _opts) do
    chat = Conversations.get!(id)
    %{project: project, ticket: ticket} = Conversations.context(chat)

    Mix.shell().info("#{chat.id} — #{project.name}#{about(ticket)} — #{chat.status}")
    Mix.shell().info("#{chat.turns} turn(s), $#{chat.cost_usd}\n")

    Enum.each(Conversations.messages(chat.id), fn message ->
      Mix.shell().info("#{marker(message)} #{message.text}\n")
    end)
  end

  defp dispatch(_args, _opts), do: Mix.raise("usage: mix forge.chat open|say|show|close ...")

  # Anything that has to reach the worker runs where the workers are. Refusing is the point:
  # doing it here would record the message and deliver it nowhere, and the conversation would
  # look like it had stopped replying.
  defp on_node(opts, module, function, [chat | _rest] = args) do
    case {opts[:node], chat.status} do
      {nil, status} when status in [:pending, :running] ->
        Mix.raise("""
        #{chat.id} is #{status}, so this has to run on the node holding its worker.

        Add --node forge@#{hostname()} (the platform must be started with that --sname).
        Without it the message would be written to the log and delivered to nobody.
        """)

      {nil, _stopped} ->
        apply(module, function, args)

      {node, _status} ->
        remote(String.to_atom(node), module, function, args)
    end
  end

  defp remote(node, module, function, args) do
    unless Node.connect(node) do
      Mix.raise("cannot reach #{node}; is the platform running with that name and cookie?")
    end

    :erpc.call(node, module, function, args, :infinity)
  end

  defp hostname do
    {name, 0} = System.cmd("hostname", ["-s"])
    String.trim(name)
  end

  defp said([]), do: Mix.raise("say something")

  defp said(words) do
    case words |> Enum.join(" ") |> String.trim() do
      "" -> Mix.raise("say something")
      text -> text
    end
  end

  defp about(nil), do: ""
  defp about(ticket), do: " ##{ticket.number}"

  defp marker(%{role: :user, delivered: true}), do: "you:"
  defp marker(%{role: :user}), do: "you (queued):"
  defp marker(%{role: :assistant}), do: "agent:"
end
