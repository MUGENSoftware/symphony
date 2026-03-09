import Config

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
