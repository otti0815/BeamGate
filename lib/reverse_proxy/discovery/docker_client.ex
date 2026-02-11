defmodule ReverseProxy.Discovery.DockerClient do
  @moduledoc false

  def list_containers do
    get_json("/containers/json?all=1")
  end

  def inspect_container(id) do
    get_json("/containers/#{id}/json")
  end

  defp get_json(path) do
    url = base_url() <> path

    request = Finch.build(:get, url, [{"accept", "application/json"}])

    case Finch.request(request, ReverseProxy.Finch, receive_timeout: 4_000) do
      {:ok, %Finch.Response{status: 200, body: body}} -> Jason.decode(body)
      {:ok, %Finch.Response{status: code, body: body}} -> {:error, {:http_error, code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_url do
    Application.get_env(:reverse_proxy, :docker_api_base, "http://localhost:2375")
    |> String.trim_trailing("/")
  end
end
