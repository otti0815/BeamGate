defmodule ReverseProxyWeb.ErrorHTML do
  use ReverseProxyWeb, :html

  def render(_template, _assigns), do: "Something went wrong"
end
