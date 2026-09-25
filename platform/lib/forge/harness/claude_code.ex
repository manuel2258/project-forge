defmodule Forge.Harness.ClaudeCode do
  @moduledoc """
  What the platform knows about Claude Code: the two kinds of secret it takes, and how to ask
  Anthropic whether one works.

  The check is the request `ForgeWorker.Harness.ClaudeCode`'s probe used to make with the
  machine's own token — `GET /v1/models` — moved here because the platform now holds the
  accounts and a machine holds none (`docs/design/credentials.md` § Checked on save). It is free
  and unbilled, and it answers both questions at once: whether the provider accepts the secret,
  and which models it may use.
  """

  @behaviour Forge.Harness

  @models_url "https://api.anthropic.com/v1/models?limit=100"
  @api_version "2023-06-01"
  # The header that lets a subscription token — the one `claude setup-token` mints — authenticate
  # an ordinary API request. Without it the same token is refused as though it were an API key.
  @oauth_beta "oauth-2025-04-20"
  @timeout_ms 10_000

  @impl true
  def label, do: "Claude Code"

  # The order is the harness's documented precedence: `ANTHROPIC_API_KEY` wins over the OAuth
  # token when both are set, which is why the driver on the worker only ever sets one.
  @impl true
  def kinds, do: [{"api_key", "API key"}, {"oauth", "Subscription token (claude setup-token)"}]

  @impl true
  def check(kind, %{"token" => token}) when is_binary(token) and kind in ["api_key", "oauth"] do
    [
      url: @models_url,
      headers: auth_headers(kind, token) ++ [{"anthropic-version", @api_version}],
      receive_timeout: @timeout_ms,
      retry: false
    ]
    |> Keyword.merge(req_options())
    |> Req.new()
    |> Req.get()
    |> answer()
  rescue
    _error -> {:error, {:unreachable, "the request failed"}}
  end

  def check(_kind, _secret), do: {:error, {:unreachable, "not a secret this harness takes"}}

  # **Every failure is reduced to a phrase chosen here**, and nothing from the response or the
  # exception is passed through except an atom. The request's headers are the secret, and an
  # HTTP client's error is exactly the kind of struct that carries them: `inspect/1` on one is
  # how the OIDC client secret reached the production log (`Forge.Accounts.Oidc.describe_error/1`).
  defp answer({:ok, %{status: 200, body: %{"data" => data}}}) when is_list(data),
    do: {:ok, Enum.flat_map(data, &model/1)}

  defp answer({:ok, %{status: status}}) when status in [401, 403], do: {:error, :refused}
  defp answer({:ok, %{status: 200}}), do: {:error, {:unreachable, "an answer it did not expect"}}
  defp answer({:ok, %{status: status}}), do: {:error, {:unreachable, "HTTP #{status}"}}
  defp answer({:error, %{reason: :timeout}}), do: {:error, {:unreachable, "timed out"}}

  defp answer({:error, %{reason: reason}}) when is_atom(reason),
    do: {:error, {:unreachable, Atom.to_string(reason)}}

  defp answer(_other), do: {:error, {:unreachable, "the request failed"}}

  # An OAuth token is a bearer token and needs the beta header; an API key is an `x-api-key`.
  # Sending one as the other is a 401, which is why the two are not merged.
  defp auth_headers("oauth", token),
    do: [{"authorization", "Bearer " <> token}, {"anthropic-beta", @oauth_beta}]

  defp auth_headers("api_key", token), do: [{"x-api-key", token}]

  defp model(%{"id" => id} = model) when is_binary(id),
    do: [%{"id" => id, "name" => model["display_name"] || id}]

  defp model(_other), do: []

  # Where the tests put a provider of their own. Set once in `config/test.exs` to a `Req.Test`
  # stub, whose ownership is per process — so a test answers the request itself without touching
  # node-global configuration, which is how this suite has broken twice.
  defp req_options, do: Application.get_env(:forge, __MODULE__, [])[:req_options] || []
end
