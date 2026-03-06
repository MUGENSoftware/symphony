defmodule SymphonyElixir.Web.Assets do
  @moduledoc """
  Compile-time embedded assets for the observability dashboard.

  All assets are read at compile time and stored as module attributes
  so the escript has no runtime dependency on priv/ directories.
  """

  @external_resource Path.join(:code.priv_dir(:phoenix), "static/phoenix.js")
  @external_resource Path.join(:code.priv_dir(:phoenix_live_view), "static/phoenix_live_view.js")

  @phoenix_js File.read!(Path.join(:code.priv_dir(:phoenix), "static/phoenix.js"))
  @live_view_js File.read!(Path.join(:code.priv_dir(:phoenix_live_view), "static/phoenix_live_view.js"))

  @dashboard_css """
  *,*::before,*::after{box-sizing:border-box}
  body{font-family:Menlo,Monaco,monospace;margin:0;padding:24px;background:#f4efe6;color:#1f1d1a}
  h1{margin:0 0 16px;font-size:1.4em}
  .grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
  .card{padding:16px;border-radius:12px;background:#fffdf8;border:1px solid #d8cfbf;overflow:auto}
  .card h2{margin:0 0 8px;font-size:1em}
  .badge{display:inline-block;padding:2px 8px;border-radius:6px;font-size:0.85em;font-weight:bold}
  .badge-running{background:#d4edda;color:#155724}
  .badge-retrying{background:#fff3cd;color:#856404}
  .badge-error{background:#f8d7da;color:#721c24}
  table{width:100%;border-collapse:collapse;font-size:0.85em}
  th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #e8e0d0}
  th{font-weight:bold;color:#6b6358}
  pre{padding:16px;border-radius:12px;background:#fffdf8;border:1px solid #d8cfbf;overflow:auto;font-size:0.85em}
  .refresh-btn{background:#1f1d1a;color:#fffdf8;border:none;padding:6px 14px;border-radius:8px;cursor:pointer;font-family:inherit;font-size:0.85em}
  .refresh-btn:hover{background:#3a3630}
  .counts{display:flex;gap:12px;margin-bottom:12px}
  .count-item{font-size:0.9em}
  .muted{color:#8a8278}
  """

  @spec css() :: String.t()
  def css, do: @dashboard_css

  @spec phoenix_js() :: String.t()
  def phoenix_js, do: @phoenix_js

  @spec live_view_js() :: String.t()
  def live_view_js, do: @live_view_js
end
