import Config

config :logger, :default_formatter, metadata: [:issue_id, :issue_identifier, :session_id, :run_id, :trace_id, :span_id]
