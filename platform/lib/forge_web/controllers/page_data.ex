defmodule ForgeWeb.PageData do
  @moduledoc """
  What the two JSON doors to a page's store — `ForgeWeb.JobPagesController` for a running job and
  `ForgeWeb.Api.PageController` for a person's or a project's token — say, so that they cannot
  disagree about a shape or a status (`docs/design/pages.md` § How a running job reaches the store).

  - `409 changed` — the key moved on since the writer read it; `current` is the key as it is now
    (`value` and `counter`), or `null` when it is not there.
  - `409 read_only` — the ticket is done or cancelled, or the chat has ended; `detail` says which.
  - `413 limit` — a value, a key, the number of keys or the page's total is over its limit; `limit`
    names it and `max` is its number.
  - `400 counter_required` — a job's or a token's write that does not say which counter it expects.
  - `404` for a page or key that is not there, `403` for a command, which reaches no page, and for a write that is not allowed.

  **A value is never logged**, here or anywhere under it: an error that is not mapped is logged by
  its shape only.
  """

  import Plug.Conn

  alias Forge.Pages
  alias Forge.Pages.{Entry, Page}

  require Logger

  @doc "The pages of a scope that have a version, as the doors list them."
  @spec pages(Pages.scope()) :: [map()]
  def pages(scope) do
    read_only = read_only(Pages.read_only(scope))

    for %{page: page, version: version} <- Pages.list(scope) do
      %{
        name: page.name,
        version: version.version,
        files: version.files |> Map.keys() |> Enum.sort(),
        keys: page.key_count,
        read_only: read_only
      }
    end
  end

  @doc "One key as the doors show it: its value, its counter and when it was written."
  @spec entry(Entry.t()) :: map()
  def entry(%Entry{} = entry),
    do: %{
      key: entry.key,
      value: entry.value,
      counter: entry.counter,
      written_at: entry.written_at
    }

  @doc "A page's whole store: every key, and whether it can be written now."
  @spec data(Page.t(), [Entry.t()], false | {true, atom()}) :: map()
  def data(%Page{} = page, entries, read_only),
    do: %{
      page: page.name,
      read_only: read_only(read_only),
      entries: Enum.map(entries, &entry/1)
    }

  @doc "`false`, or the reason a page cannot be written, as text."
  @spec read_only(false | {true, atom()}) :: false | String.t()
  def read_only(false), do: false
  def read_only({true, reason}), do: Atom.to_string(reason)

  @doc """
  The counter a write names, from the request's parameters: `{:ok, n}`, `{:ok, nil}` for a key
  expected to be absent (`null`, in a body or as `?counter=null`), or `:missing` when it names none
  and `:invalid` when it is not a counter.
  """
  @spec counter(map()) :: {:ok, non_neg_integer() | nil} | :missing | :invalid
  def counter(%{"counter" => counter}), do: parse(counter)
  def counter(_params), do: :missing

  @doc "The `value` of a write's body, which both JSON doors need and neither may read differently."
  @spec value(map()) :: {:ok, term()} | {:error, :no_value}
  def value(%{"value" => value}), do: {:ok, value}
  def value(_params), do: {:error, :no_value}

  defp parse(nil), do: {:ok, nil}
  defp parse("null"), do: {:ok, nil}
  defp parse(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp parse(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> {:ok, n}
      _other -> :invalid
    end
  end

  defp parse(_other), do: :invalid

  @doc "Answers a store's `{:error, reason}`; every shape the store and the doors refuse with."
  @spec error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def error(conn, {:changed, current}) do
    respond(conn, 409, "changed", "the key changed since it was read", %{
      current: current && %{value: current.value, counter: current.counter}
    })
  end

  def error(conn, {:read_only, reason}),
    do: respond(conn, 409, "read_only", read_only_words(reason), %{why: Atom.to_string(reason)})

  def error(conn, {:limit, name, max}),
    do:
      respond(conn, 413, "limit", "over the #{name} limit of #{max}", %{
        limit: to_string(name),
        max: max
      })

  def error(conn, {:invalid_key, why}),
    do: respond(conn, 422, "invalid_key", "the key is not valid: #{why}", %{})

  def error(conn, :invalid_value) do
    respond(
      conn,
      422,
      "invalid_value",
      "the value is not JSON, or has a NUL character in a string",
      %{}
    )
  end

  def error(conn, :counter_required),
    do:
      respond(
        conn,
        400,
        "counter_required",
        "name the counter you expect: the key's counter, or null for a key that is not there",
        %{}
      )

  def error(conn, :bad_counter),
    do:
      respond(
        conn,
        400,
        "bad_counter",
        "counter is a whole number, or null for a key that is not there",
        %{}
      )

  def error(conn, :no_value),
    do: respond(conn, 400, "bad_request", "the body needs a \"value\"", %{})

  def error(conn, :not_found), do: respond(conn, 404, "not_found", nil, %{})

  def error(conn, :forbidden),
    do: respond(conn, 403, "forbidden", "you may not do this here", %{})

  def error(conn, other) do
    # The shape only: a reason may hold a value, and no value is ever written to the log.
    shape = if is_tuple(other), do: elem(other, 0), else: other
    Logger.error("page request failed: #{inspect(shape)}")
    respond(conn, 500, "internal", nil, %{})
  end

  defp read_only_words(:done), do: "the ticket is done, so its pages are read only"
  defp read_only_words(:cancelled), do: "the ticket is cancelled, so its pages are read only"
  defp read_only_words(:chat_ended), do: "the chat has ended, so its pages are read only"
  defp read_only_words(_other), do: "the page is read only"

  defp respond(conn, status, reason, detail, extra) do
    body = %{error: Map.merge(%{reason: reason, detail: detail}, extra)}

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(body)
    |> halt()
  end
end
