# frozen_string_literal: true

module UI
  module Components
    # Every upload and where it is, grouped by who has it: the ones waiting
    # for a person first, then the ones being scanned, then the finished
    # ones. Rows are Expenses::Submissions::Row, newest first within a group.
    # The page re-renders this list, by its id, whenever the read model commits.
    class SubmissionList < Phlex::HTML
      GROUPS = {
        needs_you: 'Needs you',
        in_progress: 'Being read',
        done: 'Done'
      }.freeze

      def initialize(rows)
        @rows = rows
      end

      def view_template
        section(id: 'submissions', class: 'submissions', aria: { label: 'Uploads' }) do
          if @rows.empty?
            p(class: 'submissions__empty') { 'Nothing here yet. Drop your first receipt above.' }
            next
          end

          rows = @rows.map { [it, Status.for(it.machine)] }.group_by { |_, status| status.group }
          GROUPS.each do |group, title|
            next unless rows[group]

            section(class: "submissions__group submissions__group--#{group}") do
              h2(class: 'submissions__title') do
                plain title
                span(class: 'submissions__count') { rows[group].size.to_s }
              end
              ol(class: 'submissions__list') { rows[group].each { |sub, status| row(sub, status) } }
            end
          end
        end
      end

      private

      def row(sub, status)
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
