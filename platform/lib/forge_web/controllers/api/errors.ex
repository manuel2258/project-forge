defmodule ForgeWeb.Api.Errors do
  @moduledoc """
  A refusal as data: `{status, reason, detail}`, what the JSON API would have answered, for a door
  that is not a controller (`ForgeWeb.Mcp`).

  **The table is `ForgeWeb.Api.FallbackController`'s, asked and not copied.** It answers a bare
  connection and this reads the status and body it wrote, so a clause added to the fallback is the
  MCP door's the same day and the two doors cannot disagree about a status — which a second table
  would, the first time somebody added a refusal to one. Page-store refusals are
  `ForgeWeb.PageData`'s, the same way.
  """

  alias ForgeWeb.Api.FallbackController

  @type t :: %{status: pos_integer(), body: map()}

  @doc "What the API answers for `{:error, reason}`: its status and its `{error: {reason, detail}}` body."
  @spec of(term()) :: t()
  def of(reason), do: answered(FallbackController.call(blank(), {:error, reason}))

  @doc "What the pages' store doors answer for `reason` (`ForgeWeb.PageData.error/2`)."
  @spec of_page(term()) :: t()
  def of_page(reason), do: answered(ForgeWeb.PageData.error(blank(), reason))

  @doc "A refusal with no operation behind it: a token that may not write."
  @spec forbidden(String.t()) :: t()
  def forbidden(detail),
    do: %{status: 403, body: %{"error" => %{"reason" => "forbidden", "detail" => detail}}}

  # A connection that goes nowhere: Plug's test adapter keeps what is sent instead of sending it.
  defp blank, do: Plug.Test.conn(:post, "/")

  defp answered(%Plug.Conn{status: status, resp_body: body}),
    do: %{status: status, body: body |> IO.iodata_to_binary() |> Phoenix.json_library().decode!()}
end
