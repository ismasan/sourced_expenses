# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe Submissions do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.uuid }

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })
    def row = Submissions.recent(db, limit: 1000).find { it.expense_id == expense_id }

    # Projects each history in turn, as separate batches would.
    def project(*histories)
      histories.each do |history|
        history.reduce(with_reactor(Submissions, expense_id:)) { |r, m| r.given(m) }.then! { nil }
      end
    end

    let(:uploaded) do
      decided(Expense, { expense_id: }, cmd(Expense::UploadDocument, filename: 'lunch.pdf', content_type: 'application/pdf',
                                                                     file_ref: 'f1', filing_country: 'NL'))
    end

    it 'lists an upload at the step its scan is at' do
      project(uploaded)

      expect(row).to have_attributes(filename: 'lunch.pdf', machine: %w[scanning scanning.preparing])
    end

    it 'follows the scan across batches, with what it read' do
      extracting = decided(Expense, { expense_id: }, cmd(Expense::Scanning::CompletePreparation, processed_file_ref: 'f1'), given: uploaded)
      read = decided(Expense, { expense_id: }, cmd(Expense::Scanning::CompleteExtraction, description: 'Café - Lunch', total_amount: 24.2,
                                                                          currency: 'EUR', date: '2026-08-09', confidence: 'high'),
                     given: extracting)
      project(uploaded, extracting - uploaded, read - extracting)

      expect(row).to have_attributes(machine: %w[scanning scanning.cleaning], description: 'Café - Lunch',
                                     total_cents: 2420, currency: 'EUR', incurred_on: Date.new(2026, 8, 9))
    end

    it 'keeps why a scan failed' do
      failed = decided(Expense, { expense_id: }, cmd(Expense::Scanning::FailPreparation, reason: 'Too big'), given: uploaded)
      project(failed)

      expect(row).to have_attributes(machine: ['scan_failed'], failure: 'Too big')
      expect(row.in?('scan_failed')).to be(true)
    end
  end
end
