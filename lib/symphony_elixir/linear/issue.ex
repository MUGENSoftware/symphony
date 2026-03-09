defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :parent,
    :serial_predecessor,
    child_execution_mode: :parallel,
    blocked_by: [],
    sub_issues: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type relation_ref :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          state: String.t() | nil
        }

  @type child_execution_mode :: :parallel | :serial

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          parent: relation_ref() | nil,
          serial_predecessor: relation_ref() | nil,
          child_execution_mode: child_execution_mode(),
          blocked_by: [relation_ref()],
          sub_issues: [relation_ref()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
