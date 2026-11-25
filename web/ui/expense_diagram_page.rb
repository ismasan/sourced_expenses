# frozen_string_literal: true

module UI
  # An expense's Diagram tab (DiagramTab).
  class ExpenseDiagramPage < ExpensePage
    include DiagramTab

    path '/expenses/:expense_id/diagram'
  end
end
