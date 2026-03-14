import Config

project_version = Mix.Project.config()[:version] || "0.1.0"

config :logger, :default_formatter,
  metadata: [
    :issue_id,
    :issue_identifier,
    :session_id,
    :run_id,
    :trace_id,
    :span_id,
    :event,
    :measurements,
    :metadata,
    :otel_endpoint,
    :otel_protocol,
    :prometheus_port
  ]

config :opentelemetry,
  resource: [
    service: [
      name: "symphony-elixir",
      version: project_version
    ]
  ]
