defmodule ForgeWeb.NotAllowed do
  @moduledoc """
  Raised for `/accounts` reached by an account that is not a node admin's, and rendered by
  `ForgeWeb.ErrorHTML` as the not-allowed page in the frame (`docs/design/ui.md` § Not found).
  The one page whose existence is no secret: everywhere else a miss is a miss, and a project the
  viewer is not in is `404` like one that does not exist.
  """
  defexception message: "only a node admin governs accounts", plug_status: 403
end
