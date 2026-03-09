defmodule SymphonyElixir.Web.DashboardLive do
  @moduledoc """
  LiveView operations dashboard with PubSub-driven real-time updates.
  """

  use Phoenix.LiveView

  alias SymphonyElixir.Web.Presenter

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "orchestrator:updates")
    end

    {orchestrator, timeout} = orchestrator_config()
    payload = Presenter.state_payload(orchestrator, timeout)

    {:ok, assign(socket, payload: payload, orchestrator: orchestrator, snapshot_timeout_ms: timeout)}
  end

  @impl true
  def handle_info(:state_changed, socket) do
    payload = Presenter.state_payload(socket.assigns.orchestrator, socket.assigns.snapshot_timeout_ms)
    {:noreply, assign(socket, payload: payload)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Presenter.request_refresh(socket.assigns.orchestrator)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Symphony Dashboard</h1>

    <div class="counts">
      <span class="count-item">
        <span class="badge badge-running">{running_count(@payload)}</span> running
      </span>
      <span class="count-item">
        <span class="badge badge-retrying">{retrying_count(@payload)}</span> retrying
      </span>
    </div>

    <button class="refresh-btn" phx-click="refresh">Refresh</button>

    <div class="grid" style="margin-top:16px">
      <div class="card">
        <h2>Running</h2>
        <%= if running_list(@payload) != [] do %>
          <table>
            <thead>
              <tr><th>Issue</th><th>State</th><th>Turns</th><th>Tokens</th><th>Last Event</th></tr>
            </thead>
            <tbody>
              <%= for entry <- running_list(@payload) do %>
                <tr>
                  <td>{entry["issue_identifier"]}</td>
                  <td>{entry["state"]}</td>
                  <td>{format_turns(entry["turn_count"], entry["max_turns"])}</td>
                  <td>{get_in(entry, ["tokens", "total_tokens"])}</td>
                  <td class="muted">{entry["last_message"] || "—"}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% else %>
          <p class="muted">No running agents.</p>
        <% end %>
      </div>

      <div class="card">
        <h2>Retrying</h2>
        <%= if retrying_list(@payload) != [] do %>
          <table>
            <thead>
              <tr><th>Issue</th><th>Attempt</th><th>Due At</th><th>Error</th></tr>
            </thead>
            <tbody>
              <%= for entry <- retrying_list(@payload) do %>
                <tr>
                  <td>{entry["issue_identifier"]}</td>
                  <td>{entry["attempt"]}</td>
                  <td class="muted">{entry["due_at"] || "—"}</td>
                  <td class="badge badge-error">{entry["error"]}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% else %>
          <p class="muted">No retrying agents.</p>
        <% end %>
      </div>
    </div>

    <div class="card" style="margin-top:16px">
      <h2>Raw State</h2>
      <pre>{Jason.encode!(@payload, pretty: true)}</pre>
    </div>
    """
  end

  defp running_count(%{counts: %{running: n}}), do: n
  defp running_count(_payload), do: 0

  defp retrying_count(%{counts: %{retrying: n}}), do: n
  defp retrying_count(_payload), do: 0

  defp running_list(%{running: list}) when is_list(list) do
    Enum.map(list, fn entry -> stringify_keys(entry) end)
  end

  defp running_list(_payload), do: []

  defp retrying_list(%{retrying: list}) when is_list(list) do
    Enum.map(list, fn entry -> stringify_keys(entry) end)
  end

  defp retrying_list(_payload), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp format_turns(turn_count, max_turns) when is_integer(max_turns) and max_turns > 0,
    do: "#{turn_count}/#{max_turns}"

  defp format_turns(turn_count, _max_turns), do: turn_count

  defp orchestrator_config do
    orchestrator =
      Application.get_env(:symphony_elixir, :web_orchestrator, SymphonyElixir.Orchestrator)

    timeout =
      Application.get_env(:symphony_elixir, :web_snapshot_timeout_ms, 15_000)

    {orchestrator, timeout}
  end
end
