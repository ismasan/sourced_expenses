# frozen_string_literal: true

module UI
  module Components
    # Uploaded documents and where each one is: its status and file, then
    # what the scan read (or why it stopped). Rows are
    # Expenses::DocumentList::Row, in the order given, styled as
    # ExpenseRows' (its stylesheet).
    class DocumentRows < Phlex::HTML
      def initialize(rows)
        @rows = rows
      end

      def view_template
        ol(class: 'submissions__list') { @rows.each { row(it) } }
      end

      private

      def row(doc)
        status = Status.for(doc.machine, machine: :document)
        li(id: "document-#{doc.document_id}", class: "submission submission--#{status.stage}") do
          a(class: 'submission__link', href: "/documents/#{doc.document_id}") do
            span(class: 'submission__head') do
              render StatusBadge.new(status, size: :small)
              span(class: 'submission__file') { doc.filename }
            end
            span(class: 'submission__amount') { Money.format(doc.total_cents, doc.currency) } if amount?(doc, status)
            detail(doc, status)
          end
        end
      end

      # A rejected or failed scan's figures aren't worth showing: its reason is.
      def amount?(doc, status) = doc.total_cents && doc.currency && !%w[rejected failed].include?(status.kind)

      # What the scan read, or why it stopped.
      def detail(doc, status)
        case status.kind
        when 'failed' then span(class: 'submission__reason') { doc.failure } if doc.failure
        when 'rejected' then span(class: 'submission__reason') { doc.rejection } if doc.rejection
        else span(class: 'submission__description') { doc.description } if doc.description
        end
      end
    end
  end
end
