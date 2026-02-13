defmodule BeamGate.Discovery.RuleParser do
  @moduledoc false

  def parse(nil), do: %{host: nil, path_prefix: "/"}

  def parse(rule) when is_binary(rule) do
    %{
      host: parse_host(rule),
      path_prefix: parse_path_prefix(rule) || "/"
    }
  end

  defp parse_host(rule) do
    case Regex.run(~r/Host\(([^)]+)\)/i, rule) do
      [_, host] -> host |> strip_quotes() |> String.trim()
      _ -> nil
    end
  end

  defp parse_path_prefix(rule) do
    case Regex.run(~r/PathPrefix\(([^)]+)\)/i, rule) do
      [_, prefix] -> prefix |> strip_quotes() |> String.trim()
      _ -> nil
    end
  end

  defp strip_quotes(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("\"")
    |> String.trim_trailing("'")
  end
end
