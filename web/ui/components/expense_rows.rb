# frozen_string_literal: true

module UI
  module Components
    # Expenses and where each one is: its status, its description and
    # category, its amount and date. Rows are Expenses::ExpenseList::Row, in
    # the order given. Each row's edge and badge are in its stage's colour
    # (see UI::Status). DocumentRows lists documents the same way, with this
    # stylesheet.
    class ExpenseRows < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/submission_list.css', path: 'submission_list.css'

      def initialize(rows)
        @rows = rows
      end

      def view_template
        ol(class: 'submissions__list') { @rows.each { row(it) } }
      end

      private

      # Two lines, like a ledger. On the left, the status and the
      # description, then its category under them; on the right, the amount
      # over the date.
      def row(exp)
        status = Status.for(exp.machine)
        li(id: "expense-#{exp.expense_id}", class: "submission submission--#{status.stage}") do
          a(class: 'submission__link', href: "/expenses/#{exp.expense_id}") do
            span(class: 'submission__head') do
              render StatusBadge.new(status, size: :small)
              span(class: 'submission__file') { exp.description || 'New expense' }
            end
            span(class: 'submission__amount') { Money.format(exp.total_cents, exp.currency) } if exp.total_cents && exp.currency
            detail(exp)
            time(class: 'submission__date', datetime: exp.incurred_on.iso8601) { exp.incurred_on.strftime('%-d %b %Y') } if exp.incurred_on
          end
        end
      end

      # Who it's from and its category.
      def detail(exp)
        return unless exp.vendor || exp.category

        span(class: 'submission__description') do
          plain exp.vendor.to_s
          if exp.category
            span(class: ['submission__category', ('submission__category--suggested' unless exp.category_chosen)],
                 title: exp.category_chosen ? 'Category' : 'Suggested category') { Expenses.category_label(exp.category) }
          end
        end
      end
    end
  end
end
