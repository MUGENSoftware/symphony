defmodule SymphonyElixir.Claude.DynamicTool do
  @moduledoc """
  Behaviour for Claude dynamic tools.

  Each tool module implements this behaviour and is registered in
  `DynamicToolRegistry`. The registry aggregates tool specs from all
  enabled modules and dispatches `execute/3` calls to the correct one.
  """

  @type tool_response :: %{required(String.t()) => term()}

  @doc "Returns the list of tool spec maps sent to Claude at thread/start."
  @callback tool_specs() :: [map()]

  @doc "Executes a tool call. `opts` carries context like `:workspace` path."
  @callback execute(tool_name :: String.t(), arguments :: term(), opts :: keyword()) ::
              tool_response()

  @doc "Whether this tool module is currently active (based on config)."
  @callback enabled?() :: boolean()

  # -- Shared response helpers used by all tool implementations --

  @spec success_response(term(), boolean()) :: tool_response()
  def success_response(payload, success?) do
    %{
      "success" => success?,
      "contentItems" => [%{"type" => "inputText", "text" => format_payload(payload)}]
    }
  end

  @spec error_response(term()) :: tool_response()
  def error_response(payload) do
    %{
      "success" => false,
      "contentItems" => [%{"type" => "inputText", "text" => format_payload(payload)}]
    }
  end

  @spec format_payload(term()) :: String.t()
  def format_payload(payload) do
    if is_map(payload) or is_list(payload) do
      case Jason.encode(payload) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(payload)
      end
    else
      inspect(payload)
    end
  end
end
