defmodule ForgeWeb.DeviceHTML do
  @moduledoc "The page a device is shown when the server cannot be reached (`ForgeWeb.DeviceController`)."
  use ForgeWeb, :html

  embed_templates "device_html/*"
end
