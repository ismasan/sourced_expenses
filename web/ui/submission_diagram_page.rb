# frozen_string_literal: true

module UI
  # A submission's Diagram tab: the Expense statechart, with the states the
  # expense is in lit and the moves it can make next highlighted. Live, or
  # at a step of its history, like the Submission tab.
  class SubmissionDiagramPage < SubmissionPage
    path '/submissions/:expense_id/diagram'

    def tab = :diagram

    private

    def render_tab(_kind)
      section(class: 'machine-view', aria: { label: 'Statechart' }) do
        render Sourced::UI::Components::Statechart.new(@expense.to_h, title: 'Expense statechart')
        render Sourced::UI::Components::StatechartLegend.new
      end
    end
  end
end
