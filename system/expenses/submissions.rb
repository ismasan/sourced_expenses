# frozen_string_literal: true

require 'json'

module Expenses
  # The read model behind the home page's list: one row per uploaded
  # document, in the `submissions` table, rewritten whenever its expense
  # moves. Where the machine is (its paths) comes from the state events'
  # entered and exited paths, so the list never loads a machine.
  #
  # Sidereal publishes Submissions::Projected after every committed batch,
  # which is what the page reacts to.
  class Submissions < Sourced::Projector::StateStored
    partition_by expense_id: Types::UUID::V4

    dep :db

    Row = ::Data.define(:expense_id, :filename, :machine, :failure, :rejection, :description,
                        :total_cents, :currency, :incurred_on, :uploaded_at, :updated_at) do
      def in?(path) = machine.include?(path)
    end

    COLUMNS = %i[filename content_type file_ref machine failure rejection description
                 total_cents currency incurred_on uploaded_at updated_at].freeze

    # The latest uploads first.
    def self.recent(db, limit: 50)
      db[:submissions].reverse(:uploaded_at).limit(limit).map do |row|
        Row.new(**row.slice(*Row.members), machine: JSON.parse(row[:machine]))
      end
    end

    context { { machine: [] } }

    load_context do |partition|
      row = db[:submissions].where(expense_id: partition[:expense_id]).first
      row&.merge(machine: JSON.parse(row[:machine]))
    end

    Expense.transition_classes.each do |klass|
      evolve klass do |row, evt|
        row[:expense_id] = evt.payload.expense_id
        row[:machine] = (row[:machine] - evt.payload.exited) | evt.payload.entered
        row[:updated_at] = evt.created_at
      end
    end

    evolve Expense::DocumentUploaded do |row, evt|
      row.merge!(evt.payload.to_h.slice(:expense_id, :filename, :content_type, :file_ref))
      row[:uploaded_at] = evt.created_at
    end

    # A rescan starts from nothing.
    evolve Expense::ScanRequested do |row, _evt|
      row.merge!(failure: nil, rejection: nil, description: nil, total_cents: nil, currency: nil, incurred_on: nil)
    end

    evolve Expense::StepFailed do |row, evt|
      row[:failure] = evt.payload.reason
    end

    evolve Expense::Scanning::DocumentVerified do |row, evt|
      row[:rejection] = evt.payload.explanation unless evt.payload.is_invoice_or_receipt
    end

    evolve Expense::Scanning::ExtractionRecorded do |row, evt|
      total = evt.payload.total_amount
      row.merge!(
        description: evt.payload.description,
        total_cents: total && (total * 100).round,
        currency: evt.payload.currency,
        incurred_on: Submissions.date(evt.payload.date)
      )
    end

    evolve Expense::Scanning::DateRechecked do |row, evt|
      row[:incurred_on] = Submissions.date(evt.payload.corrected_date) if evt.payload.corrected_date
    end

    evolve Expense::Scanning::TextCleaned do |row, evt|
      row[:description] = evt.payload.description
    end

    evolve Expense::ExpenseFiled do |row, evt|
      row.merge!(
        description: evt.payload.description,
        total_cents: evt.payload.net_price_cents + evt.payload.tax_amount_cents,
        currency: evt.payload.currency,
        incurred_on: evt.payload.incurred_on
      )
    end

    sync do |context:, **|
      next unless context[:filename]

      row = context.slice(*COLUMNS).merge(machine: JSON.generate(context[:machine]))
      db[:submissions].insert_conflict(target: :expense_id, update: row)
                      .insert(row.merge(expense_id: context[:expense_id]))
    end

    def self.date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
