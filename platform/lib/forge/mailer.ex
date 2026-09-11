defmodule Forge.Mailer do
  @moduledoc "Delivers account emails such as magic-link logins."
  use Swoosh.Mailer, otp_app: :forge
end
