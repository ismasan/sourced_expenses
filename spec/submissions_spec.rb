# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe Submissions do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.hex(16) }

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
                                                                     file_ref: 'f1', filing_country: 'NL'),
              cmd(Expense::StartScan))
    end

    it 'deletes every row when its group is reset, to build them again' do
      db.transaction(rollback: :always, auto_savepoint: true) do
        project(uploaded)
        expect(row).not_to be_nil

        Submissions.on_reset

        expect(db[:submissions].count).to eq(0)
      end
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

    describe 'the VAT treatment' do
      let(:extraction) do
        { document_type: 'invoice', description: 'Café - Lunch', total_amount: 24.2, net_amount: 20.0, tax_amount: 4.2,
          currency: 'EUR', date_as_printed: '9 Aug 2026', date: '2026-08-09', confidence: 'high', supplier_country_code: 'NL',
          reverse_charge: false }
      end

      def after(*commands, given:) = decided(Expense, { expense_id: }, *commands, given:)

      let(:read) do
        after(cmd(Expense::Scanning::CompletePreparation, processed_file_ref: 'f1'),
              cmd(Expense::Scanning::CompleteExtraction, **extraction), given: uploaded)
      end

      it 'suggests the rule’s treatment once the scan has read the figures, in a batch after the upload' do
        project(uploaded, read - uploaded)

        expect(row).to have_attributes(vat_treatment: 'domestic', vat_confirmed: false, filing_country: 'NL')
      end

      it 'takes a person’s treatment for good, through a rescan' do
        confirmed = after(cmd(Expense::Scanning::CompleteCleanup, description: 'Café - Lunch', tax_description: nil),
                          cmd(Expense::ConfirmVatTreatment, treatment: 'import'), given: read)
        rescanned = after(cmd(Expense::Rescan), cmd(Expense::StartScan), cmd(Expense::Scanning::CompletePreparation, processed_file_ref: 'f1'),
                          cmd(Expense::Scanning::CompleteExtraction, **extraction), given: confirmed)
        project(uploaded, confirmed - uploaded, rescanned - confirmed)

        expect(row).to have_attributes(vat_treatment: 'import', vat_confirmed: true)
      end

      it 'suggests none for a scan that did not finish' do
        failed = after(cmd(Expense::Scanning::FailVerification, reason: 'Down'),
                       given: after(cmd(Expense::Scanning::CompletePreparation, processed_file_ref: 'f1'),
                                    cmd(Expense::Scanning::CompleteExtraction, **extraction, total_amount: nil), given: uploaded))
        project(failed)

        expect(row).to have_attributes(machine: ['scan_failed'], vat_treatment: nil)
      end
    end

    describe 'filtering' do
      around do |example|
        db.transaction(rollback: :always, auto_savepoint: true) do
          db[:submissions].delete
          example.run
        end
      end

      def submission(name, **columns)
        db[:submissions].insert(expense_id: name, filename: "#{name}.pdf", machine: '["reviewing"]', uploaded_at: Time.now,
                                updated_at: Time.now, **columns)
      end

      def ids(**filters) = Submissions.in_states(db, **filters).select_map(:expense_id).sort

      before do
        submission('suggested', category: 'travel', vat_treatment: 'domestic')
        submission('chosen', category: 'travel', category_chosen: true, vat_treatment: 'import', vat_confirmed: true)
        submission('blank')
      end

      it 'finds rows by whose category and VAT treatment they are, any of each, both together' do
        expect(ids(category_statuses: %w[suggested])).to eq(%w[suggested])
        expect(ids(category_statuses: %w[chosen none])).to eq(%w[blank chosen])
        expect(ids(vat_statuses: %w[confirmed])).to eq(%w[chosen])
        expect(ids(vat_statuses: %w[suggested none])).to eq(%w[blank suggested])
        expect(ids(category_statuses: %w[suggested chosen], vat_statuses: %w[suggested])).to eq(%w[suggested])
        expect(ids(category_statuses: [], vat_statuses: [])).to eq(%w[blank chosen suggested])
      end

      it 'finds rows by the country they are filed in' do
        db[:submissions].where(expense_id: 'chosen').update(filing_country: 'NL')
        db[:submissions].where(expense_id: 'suggested').update(filing_country: 'GB')

        expect(ids(filing_countries: %w[NL])).to eq(%w[chosen])
        expect(ids(filing_countries: %w[GB NL], vat_statuses: %w[suggested])).to eq(%w[suggested])
        expect(ids(filing_countries: [])).to eq(%w[blank chosen suggested])
      end

      it 'counts and pages by them too' do
        expect(Submissions.counts(db, vat_statuses: %w[confirmed])).to include('reviewing' => 1)
        expect(Submissions.category_counts(db, vat_statuses: %w[suggested])).to eq('travel' => 1)
        expect(Submissions.page(db, category_statuses: %w[none]).then { [it[0].map(&:expense_id), it[1]] }).to eq([%w[blank], 1])
      end
    end
  end
end
