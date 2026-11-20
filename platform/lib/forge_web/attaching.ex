defmodule ForgeWeb.Attaching do
  @moduledoc """
  What a form's `attachments` fields say, read one way by every handler
  (`docs/design/ui.md` § Attaching files).

  The box (`ForgeWeb.UI.Attach`) sends `attachments[ids][]` with `attachments[names][]` beside them —
  the staged uploads that finished, and the name each was uploaded as — and `attachments[failed][]`,
  the names of files that failed or were cut off. Nothing here is trusted: a field that is not a
  list of strings is nothing, an id that is not the sender's is refused by the claim (and the file
  named as not received), and the lists are cut so a crafted form cannot make a request larger than
  it need be.
  """

  alias Forge.Attachments.Batch

  # More than any limit lets through; the claim says which one a file passed.
  @most 50

  @doc "The batch of a form's params, whole of the form or just its `attachments` map."
  @spec batch(map()) :: Batch.t()
  def batch(%{"attachments" => %{} = fields}), do: batch(fields)

  def batch(%{} = fields) do
    ids = strings(fields["ids"])
    names = strings(fields["names"])

    uploads =
      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, index} -> %{id: id, name: Enum.at(names, index) || "file"} end)

    %Batch{uploads: uploads, not_received: strings(fields["failed"])}
  end

  @doc """
  The option every act takes (`attachments: batch`), or nothing when the form sent no files at all,
  so an act with none is called exactly as it was before there were any.
  """
  @spec opts(map()) :: keyword()
  def opts(params) do
    batch = batch(params)
    if Batch.empty?(batch), do: [], else: [attachments: batch]
  end

  @doc """
  Tells the box on the page that what it held was sent, so that it clears. Called where an act
  succeeded; a refusal leaves the files where they are, beside the text that stays.
  """
  @spec sent(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sent(socket), do: Phoenix.LiveView.push_event(socket, "attach:sent", %{})

  @doc """
  A person's *Withdraw* on a file's Docs row (`docs/design/attachments.md` § Withdrawing), on the
  pool of the page it was pressed on. The context decides who may — the attacher or an admin of the
  project — and a refusal is drawn where the press was (`ForgeWeb.WorkScreen.docs/1`'s `refusal`).
  """
  @spec withdraw(Phoenix.LiveView.Socket.t(), Forge.Attachments.pool(), map()) ::
          Phoenix.LiveView.Socket.t()
  def withdraw(socket, pool, %{"name" => name, "which" => which} = params)
      when is_binary(name) and is_binary(which) do
    user = socket.assigns.current_scope.user

    case which(which) &&
           Forge.Attachments.withdraw(pool, user, name, which(which), params["reason"]) do
      {:ok, rows} ->
        Forge.Events.notify(ticket_of(pool))

        Phoenix.LiveView.put_flash(
          socket,
          :info,
          "Withdrew #{length(rows)} #{if length(rows) == 1, do: "version", else: "versions"} of #{name}"
        )

      {:error, :forbidden} ->
        ForgeWeb.Operator.Actions.refuse(
          socket,
          "attachments:withdraw",
          "Failed: only the person who attached a file, or an admin of the project, may withdraw it"
        )

      _gone ->
        ForgeWeb.Operator.Actions.refuse(
          socket,
          "attachments:withdraw",
          "Failed: there is nothing of that file left to withdraw"
        )
    end
  end

  def withdraw(socket, _pool, _params), do: socket

  defp which("all"), do: :all

  defp which(text) do
    case Integer.parse(text) do
      {version, ""} when version > 0 -> version
      _other -> nil
    end
  end

  defp ticket_of({:ticket, id}), do: id
  defp ticket_of({:job, _id}), do: nil

  defp strings(list) when is_list(list),
    do:
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.slice(&1, 0, 255))
      |> Enum.take(@most)

  defp strings(_other), do: []
end
