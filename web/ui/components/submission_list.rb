# frozen_string_literal: true

module UI
  module Components
    # Uploads and where each one is: its status, what the scan read, or why
    # it stopped. Rows are Expenses::Submissions::Row, in the order given.
    # Each row's edge and badge are in its stage's colour (see UI::Status).
    class SubmissionList < Phlex::HTML
      def initialize(rows)
        @rows = rows
      end

      def view_template
        ol(class: 'submissions__list') { @rows.each { row(it) } }
      end

      private

      def row(sub)
        status = Status.for(sub.machine)
        li(id: "submission-#{sub.expense_id}", class: "submission submission--#{status.stage}") do
          a(class: 'submission__link', href: "/submissions/#{sub.expense_id}") do
            span(class: 'submission__file') { sub.filename }
            render StatusBadge.new(status)
            detail(sub, status)
          end
        end
      end

      # What the scan read, or why it stopped.
      def detail(sub, status)
        case status.kind
        when 'failed' then span(class: 'submission__reason') { sub.failure } if sub.failure
        when 'rejected' then span(class: 'submission__reason') { sub.rejection } if sub.rejection
        else
          return unless sub.description

          span(class: 'submission__summary') do
            span(class: 'submission__description') { sub.description }
            span(class: 'submission__amount') { format('%.2f %s', sub.total_cents / 100.0, sub.currency) } if sub.total_cents
            time(class: 'submission__date', datetime: sub.incurred_on.iso8601) { sub.incurred_on.strftime('%-d %b %Y') } if sub.incurred_on
          end
        end
      end
    end
  end
end
