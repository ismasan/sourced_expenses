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

      # Two lines, like a ledger. On the left, the status and the file, then
      # what the scan read (or why it stopped) under them; on the right, the
      # amount over the date.
      def row(sub)
        status = Status.for(sub.machine)
        li(id: "submission-#{sub.expense_id}", class: "submission submission--#{status.stage}") do
          a(class: 'submission__link', href: "/submissions/#{sub.expense_id}") do
            span(class: 'submission__head') do
              render StatusBadge.new(status, size: :small)
              span(class: 'submission__file') { sub.filename }
            end
            span(class: 'submission__amount') { Money.format(sub.total_cents, sub.currency) } if amount?(sub, status)
            detail(sub, status)
            time(class: 'submission__date', datetime: sub.incurred_on.iso8601) { sub.incurred_on.strftime('%-d %b %Y') } if sub.incurred_on && amount?(sub, status)
          end
        end
      end

      # A rejected or failed scan's figures aren't worth showing: its reason is.
      def amount?(sub, status) = sub.total_cents && sub.currency && !%w[rejected failed].include?(status.kind)

      # What the scan read, or why it stopped.
      def detail(sub, status)
        case status.kind
        when 'failed' then span(class: 'submission__reason') { sub.failure } if sub.failure
        when 'rejected' then span(class: 'submission__reason') { sub.rejection } if sub.rejection
        else
          span(class: 'submission__description') do
            plain sub.description.to_s
            if sub.category
              span(class: ['submission__category', ('submission__category--suggested' unless sub.category_chosen)],
                   title: sub.category_chosen ? 'Category' : 'Suggested category') { Expenses.category_label(sub.category) }
            end
          end if sub.description || sub.category
        end
      end
    end
  end
end
