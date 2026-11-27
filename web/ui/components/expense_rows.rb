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
      file 'ui/components/freeagent.svg', path: 'freeagent.svg'

      FREEAGENT = FreeAgent::ExpenseMapping::SOURCE

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
              span(class: 'submission__file', title: exp.description) { exp.description || 'New expense' }
            end
            span(class: 'submission__amount') { Money.format(exp.total_cents, exp.currency) } if exp.total_cents && exp.currency
            detail(exp)
            time(class: 'submission__date', datetime: exp.incurred_on.iso8601) { exp.incurred_on.strftime('%-d %b %Y') } if exp.incurred_on
          end
        end
      end

      # Its category, who it's from, a clip if it has a document, and
      # whether it came from FreeAgent or went to it.
      def detail(exp)
        return unless exp.vendor || exp.category || exp.document_id || freeagent(exp)

        span(class: 'submission__description submission__tags') do
          if exp.category
            span(class: ['submission__category', ('submission__category--suggested' unless exp.category_chosen)],
                 title: exp.category_chosen ? 'Category' : 'Suggested category') { Expenses.category_label(exp.category) }
          end
          span(class: 'submission__vendor') { exp.vendor } if exp.vendor
          document_clip if exp.document_id
          freeagent_mark(exp)
        end
      end

      # A paperclip (Feather's), for one with a document attached.
      CLIP = 'M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19' \
             'a2 2 0 0 1-2.83-2.83l8.49-8.48'

      def document_clip
        span(class: 'submission__document', title: 'Has a document') do
          svg(viewbox: '0 0 24 24', width: 16, height: 16, fill: 'none', stroke: 'currentColor', stroke_width: 2,
              stroke_linecap: 'round', stroke_linejoin: 'round', aria_hidden: 'true') { |s| s.path(d: CLIP) }
          span(class: 'visually-hidden') { 'Has a document' }
        end
      end

      # FreeAgent's logo, with an arrow down for one imported from it, up for
      # one uploaded to it, and a red cross for one whose upload (or, voided,
      # deletion there) failed.
      def freeagent_mark(exp)
        way = freeagent(exp) or return

        span(class: "submission__sync submission__sync--#{way}", title: sync_title(exp, way)) do
          img(src: asset_url('ui/components/freeagent.svg'), alt: 'FreeAgent', width: 16, height: 16)
          span(class: 'submission__sync-arrow', aria_hidden: 'true') { SYNC_MARKS.fetch(way) }
        end
      end

      SYNC_MARKS = { imported: '↓', uploaded: '↑', failed: '✕' }.freeze

      def freeagent(exp)
        if exp.source == FREEAGENT then :imported
        elsif exp.upload_failed_to?(FREEAGENT) then :failed
        elsif exp.uploaded_to?(FREEAGENT) then :uploaded
        end
      end

      def sync_title(exp, way)
        case way
        when :imported then 'Imported from FreeAgent'
        when :uploaded then 'Uploaded to FreeAgent'
        else exp.in?('voided') ? 'Not deleted on FreeAgent' : 'Not uploaded to FreeAgent'
        end
      end
    end
  end
end
