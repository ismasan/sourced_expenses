# frozen_string_literal: true

module UI
  module Components
    # The home page's list: the uploads waiting for a person, newest first.
    # Re-rendered by its id whenever the read model commits.
    class NeedsYou < Phlex::HTML
      # @param rows [Array<Expenses::Submissions::Row>] the latest of them
      # @param total [Integer] how many there are in all
      def initialize(rows, total)
        @rows = rows
        @total = total
      end

      def view_template
        section(id: 'needs-you', class: 'submissions', aria: { labelledby: 'needs-you-title' }) do
          h2(id: 'needs-you-title', class: 'submissions__title') do
            plain 'Needs you'
            span(class: 'submissions__count') { @total.to_s }
          end

          if @rows.empty?
            p(class: 'submissions__empty') do
              plain 'Nothing needs you right now. Drop receipts above, or '
              a(href: '/expenses') { 'see all expenses' }
              plain '.'
            end
            next
          end

          render SubmissionList.new(@rows)
          if @total > @rows.size
            p(class: 'submissions__more') do
              a(href: ExpensesPage.path_for(states: Expenses::Submissions::NEEDS_YOU)) { "See all #{@total}" }
            end
          end
        end
      end
    end
  end
end
