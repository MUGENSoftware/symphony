defmodule SymphonyElixir.Claude.DynamicToolRegistry do
  @moduledoc """
  Aggregates all dynamic tool modules and dispatches tool calls.

  Each tool module implements `SymphonyElixir.Claude.DynamicTool` behaviour.
  The registry filters by `enabled?/0` at call time, so tools that depend on
  config (like GitTool) are only advertised when their feature is active.
  """

  alias SymphonyElixir.Claude.DynamicTool

  @tool_modules [
    SymphonyElixir.Claude.Tools.LinearGraphqlTool,
    SymphonyElixir.Claude.Tools.GitTool
  ]

  @doc "Returns aggregated tool specs from all enabled tool modules."
  @spec tool_specs() :: [map()]
  def tool_specs do
    @tool_modules
    |> Enum.filter(& &1.enabled?())
    |> Enum.flat_map(& &1.tool_specs())
  end

  @doc "Dispatches a tool call to the module that owns the given tool name."
  @spec execute(String.t(), term(), keyword()) :: DynamicTool.tool_response()
  def execute(tool_name, arguments, opts \\ []) do
    case find_module(tool_name) do
      {:ok, mod} ->
        mod.execute(tool_name, arguments, opts)

      :error ->
        DynamicTool.error_response(%{
          "error" => %{
            "message" => ~s(Unsupported dynamic tool: "#{tool_name}".),
            "supportedTools" => Enum.map(tool_specs(), & &1["name"])
          }
        })
    end
  end

  @doc "Returns the list of all supported tool names (across enabled modules)."
  @spec supported_tool_names() :: [String.t()]
  def supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp find_module(tool_name) do
    @tool_modules
    |> Enum.filter(& &1.enabled?())
    |> Enum.find(fn mod ->
      Enum.any?(mod.tool_specs(), &(&1["name"] == tool_name))
    end)
    |> case do
      nil -> :error
      mod -> {:ok, mod}
    end
  end
end
