defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Wrapper that starts the Phoenix endpoint for the observability dashboard.

  Preserves the same public API as the previous gen_tcp-based server:
  `start_link/1`, `bound_port/1`, and `child_spec/1`.
  """

  use GenServer

  alias SymphonyElixir.Config

  defmodule State do
    @moduledoc false

    defstruct [:port, :orchestrator, :snapshot_timeout_ms, :owns_endpoint]
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, Keyword.put(opts, :port, port), name: name)

      _ ->
        :ignore
    end
  end

  @spec bound_port(GenServer.name()) :: non_neg_integer() | nil
  def bound_port(server \\ __MODULE__) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(server, :bound_port)

      _ ->
        nil
    end
  end

  @impl true
  def init(opts) do
    host = Keyword.get(opts, :host, Config.server_host())
    port = Keyword.fetch!(opts, :port)
    orchestrator = Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator)
    snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

    ip =
      case parse_host(host) do
        {:ok, ip} -> ip
        {:error, reason} -> throw({:stop, reason})
      end

    Application.put_env(:symphony_elixir, :web_orchestrator, orchestrator)
    Application.put_env(:symphony_elixir, :web_snapshot_timeout_ms, snapshot_timeout_ms)

    Application.put_env(:symphony_elixir, SymphonyElixir.Web.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: ip, port: port],
      server: true,
      secret_key_base: secret_key_base(),
      live_view: [signing_salt: "symphony_lv"],
      pubsub_server: SymphonyElixir.PubSub,
      render_errors: [formats: [json: SymphonyElixir.Web.ErrorJSON]]
    )

    case SymphonyElixir.Web.Endpoint.start_link([]) do
      {:ok, _pid} ->
        {:ok,
         %State{
           port: port,
           orchestrator: orchestrator,
           snapshot_timeout_ms: snapshot_timeout_ms,
           owns_endpoint: true
         }}

      {:error, {:already_started, _pid}} ->
        {:ok,
         %State{
           port: port,
           orchestrator: orchestrator,
           snapshot_timeout_ms: snapshot_timeout_ms,
           owns_endpoint: false
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  catch
    {:stop, reason} -> {:stop, reason}
  end

  @impl true
  def handle_call(:bound_port, _from, state) do
    port =
      case Bandit.PhoenixAdapter.server_info(SymphonyElixir.Web.Endpoint, :http) do
        {:ok, {_address, port}} -> port
        _ -> state.port
      end

    {:reply, port, %{state | port: port}}
  end

  @impl true
  def terminate(_reason, %State{owns_endpoint: true}) do
    case Process.whereis(SymphonyElixir.Web.Endpoint) do
      pid when is_pid(pid) -> Supervisor.stop(pid, :normal)
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  @spec parse_host_for_test(String.t() | :inet.ip_address()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def parse_host_for_test(host), do: parse_host(host)

  defp secret_key_base do
    :crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)
  end
end
