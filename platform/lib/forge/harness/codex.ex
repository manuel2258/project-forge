defmodule Forge.Harness.Codex do
  @moduledoc """
  What the platform knows about Codex: the two kinds of ChatGPT credential it takes, what shape
  each must have, and what a ChatGPT login says about whose it is (`docs/design/codex.md`
  § Credentials).

  **There is no call to OpenAI.** A login or a token is checked by its shape alone, so a saved
  credential says it is *not checked with OpenAI: the first job is the check*
  (`docs/design/credentials.md` § Checked on save). **Every failure is a fixed phrase chosen here**:
  nothing of what was pasted reaches an error, a log or a page, and above all not a JSON parse
  error, whose message carries the input (`Forge.Accounts.Oidc.describe_error/1` is the same
  class of trap).

  An OpenAI API key is not a kind: ChatGPT credentials only, by decision.
  """

  @behaviour Forge.Harness

  # A login is three JWTs and an account id, a few kilobytes; a hundredth of the ceiling is the
  # largest real one. The ceiling is a guard on what is parsed, not on what is expected.
  @max_login_bytes 65_536
  @max_token_bytes 4_096

  @impl true
  def label, do: "Codex"

  @impl true
  def kinds do
    [
      {"chatgpt_login", "ChatGPT login (Plus or Pro)"},
      {"access_token", "Codex access token (Business or Enterprise)"}
    ]
  end

  # A login is renewed by Codex itself and rotates, so a copy another run refreshed first stops
  # working: one run holds it at a time and what the run leaves of it comes back. A token is fixed.
  @impl true
  def traits("chatgpt_login"), do: %{exclusive: true, returns: true, checked: :shape}
  def traits("access_token"), do: %{exclusive: false, returns: false, checked: :shape}

  @impl true
  def check("chatgpt_login", %{"token" => text}) when is_binary(text) do
    with :ok <- login_size(text),
         {:ok, login} <- decode(text),
         {:ok, _tokens} <- login_tokens(login) do
      {:ok, []}
    end
  end

  def check("access_token", %{"token" => token}) when is_binary(token) do
    cond do
      token == "" -> {:error, {:malformed, "is required"}}
      byte_size(token) > @max_token_bytes -> {:error, {:malformed, "is too long to be a token"}}
      String.contains?(token, ["\n", "\r"]) -> {:error, {:malformed, "must be one line"}}
      true -> {:ok, []}
    end
  end

  def check(_kind, _secret), do: {:error, {:malformed, "is not a secret this harness takes"}}

  @doc """
  What a login says of itself, for its row: `%{account_id:, plan:}`. The account is what a returned
  login is compared against; the plan is the id token's claim, **decoded without verifying it**
  and only for display — nothing decides on it. A token says nothing.
  """
  @impl true
  def attributes("chatgpt_login", %{"token" => text}) do
    with {:ok, login} <- decode(text),
         {:ok, tokens} <- login_tokens(login) do
      %{account_id: tokens["account_id"], plan: plan(tokens["id_token"])}
    else
      _malformed -> %{}
    end
  end

  def attributes(_kind, _secret), do: %{}

  @doc "The ChatGPT account a login names, or nil — the same shape check a save makes."
  @spec account_id(String.t()) :: String.t() | nil
  def account_id(text) when is_binary(text) do
    case check("chatgpt_login", %{"token" => text}) do
      {:ok, _models} -> attributes("chatgpt_login", %{"token" => text})[:account_id]
      {:error, _why} -> nil
    end
  end

  def account_id(_other), do: nil

  # -- the shape of a login --------------------------------------------------------------------

  defp login_size(text) when byte_size(text) > @max_login_bytes,
    do: {:error, {:malformed, "is too large to be a ChatGPT login"}}

  defp login_size(_text), do: :ok

  # The error is dropped on the floor: `Jason.DecodeError` carries the input it could not read.
  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = login} -> {:ok, login}
      {:ok, _not_an_object} -> {:error, {:malformed, "is not a ChatGPT login"}}
      {:error, _carries_the_input} -> {:error, {:malformed, "is not JSON"}}
    end
  end

  # What `codex login` writes in ChatGPT mode: the three tokens and the account, no API key. A file
  # that says it is anything but ChatGPT mode, or that holds an API key, is not one.
  defp login_tokens(login) do
    with :ok <- chatgpt_mode(login),
         %{} = tokens <- login["tokens"],
         true <-
           Enum.all?(~w(access_token refresh_token id_token account_id), &present?(tokens[&1])) do
      {:ok, tokens}
    else
      {:error, _why} = error -> error
      _missing -> {:error, {:malformed, "is not a ChatGPT login: it is missing its tokens"}}
    end
  end

  defp chatgpt_mode(%{"auth_mode" => mode}) when mode not in [nil, "chatgpt"],
    do: {:error, {:malformed, "is not in ChatGPT mode"}}

  defp chatgpt_mode(%{"OPENAI_API_KEY" => key}) when is_binary(key) and key != "",
    do: {:error, {:malformed, "holds an API key, which this does not take"}}

  defp chatgpt_mode(_login), do: :ok

  defp present?(value), do: is_binary(value) and value != ""

  # The claim the id token carries its plan in, which `codex` reads the same way. Anything that
  # does not decode is no plan: display only, so a wrong answer is nothing and a crash is worse.
  defp plan(id_token) do
    with [_header, payload, _signature] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"https://api.openai.com/auth" => %{"chatgpt_plan_type" => plan}}} <-
           Jason.decode(json),
         true <- is_binary(plan) do
      String.slice(plan, 0, 40)
    else
      _no_plan -> nil
    end
  end
end
