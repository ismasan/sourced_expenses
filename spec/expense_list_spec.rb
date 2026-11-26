# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe ExpenseList do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.uuid }

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })
    def row = ExpenseList.recent(db, limit: 1000).find { it.expense_id == expense_id }
    def after(*commands, given: []) = decided(Expense, { expense_id: }, *commands, given:)

    # Projects each history in turn, as separate batches would.
    def project(*histories)
      histories.each do |history|
        history.reduce(with_reactor(ExpenseList, expense_id:)) { |r, m| r.given(m) }.then! { nil }
      end
    end

    let(:draft) do
      { description: 'Café - Lunch', vendor: 'Café', net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR',
        incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL', reverse_charge: false }
    end
    let(:document_id) { SecureRandom.hex(16) }
    let(:drafted) { after(cmd(Expense::DraftExpenseFromDocument, filing_country: 'NL', document_id:, **draft)) }

    it 'deletes every row when its group is reset, to build them again' do
      db.transaction(rollback: :always, auto_savepoint: true) do
        project(drafted)
        expect(row).not_to be_nil

        ExpenseList.on_reset

        expect(db[:expenses].count).to eq(0)
        expect(db[:expenses_search].count).to eq(0)
      end
    end

    it 'lists a drafted expense in review, with its draft, its document and the VAT treatment the rule suggests' do
      project(drafted)

      expect(row).to have_attributes(
        machine: include('reviewing'), document_id:, description: 'Café - Lunch', vendor: 'Café', total_cents: 2420,
        currency: 'EUR', incurred_on: Date.new(2026, 8, 9), filing_country: 'NL', vat_treatment: 'domestic',
        vat_confirmed: false, category: nil
      )
      expect(row.in?('reviewing')).to be(true)
    end

    it 'lists one entered by hand, with no document, and one drafted with nothing in it' do
      project(after(cmd(Expense::EnterExpense, filing_country: 'GB', description: 'Train', net_price_cents: 5000,
                                               tax_amount_cents: 0, currency: 'GBP', incurred_on: Date.new(2026, 8, 9))))
      expect(row).to have_attributes(document_id: nil, description: 'Train', total_cents: 5000, vat_treatment: 'no_vat')

      other = SecureRandom.hex(16)
      empty = decided(Expense, { expense_id: other }, Expense::DraftExpenseFromDocument.new(payload: { expense_id: other, document_id: SecureRandom.hex(16), filing_country: 'NL' }))
      empty.reduce(with_reactor(ExpenseList, expense_id: other)) { |r, m| r.given(m) }.then! { nil }
      expect(ExpenseList.recent(db, limit: 1000).find { it.expense_id == other })
        .to have_attributes(description: nil, total_cents: nil, vat_treatment: nil, machine: include('reviewing'))
    end

    it 'takes a new draft (its document read again), in a later batch' do
      redrafted = after(cmd(Expense::DraftExpenseFromDocument, filing_country: 'NL', document_id:, **draft, description: 'Café - Dinner',
                                                   net_price_cents: 3000, tax_amount_cents: 0),
                        given: drafted)
      project(drafted, redrafted - drafted)

      expect(row).to have_attributes(description: 'Café - Dinner', total_cents: 3000, vat_treatment: 'no_vat')
    end

    it 'keeps a person’s VAT treatment through a new draft' do
      confirmed = after(cmd(Expense::ConfirmVatTreatment, treatment: 'import'), given: drafted)
      redrafted = after(cmd(Expense::DraftExpenseFromDocument, filing_country: 'NL', document_id:, **draft, tax_amount_cents: 0),
                        given: confirmed)
      project(drafted, confirmed - drafted, redrafted - confirmed)

      expect(row).to have_attributes(vat_treatment: 'import', vat_confirmed: true)
    end

    it 'keeps the suggested category until a person chooses one' do
      suggested = after(cmd(Expense::SuggestCategory, category: 'travel', probability: 0.8, description: 'Café - Lunch'),
                        given: drafted)
      project(suggested)
      expect(row).to have_attributes(category: 'travel', category_chosen: false)

      chosen = after(cmd(Expense::ChooseCategory, category: 'business_entertaining'), given: suggested)
      project(chosen - suggested)
      expect(row).to have_attributes(category: 'business_entertaining', category_chosen: true)
    end

    describe 'imported' do
      let(:expense_id) { "freeagent-#{SecureRandom.hex(4)}" }

      def import(**overrides)
        cmd(Expense::ImportExpense, source: 'freeagent', external_id: expense_id.delete_prefix('freeagent-'),
                                    filing_country: 'GB', description: 'Pret - Lunch', net_price_cents: 2000,
                                    tax_amount_cents: 400, currency: 'GBP', incurred_on: Date.new(2026, 11, 18),
                                    category: 'accommodation_and_meals', source_category: 'Accommodation and Meals',
                                    vat_treatment: 'domestic', **overrides)
      end

      let(:imported) { after(import) }

      it 'lists it filed, with its source, its source’s category and VAT treatment confirmed' do
        project(imported)

        expect(row).to have_attributes(
          machine: ['filed'], source: 'freeagent', document_id: nil, description: 'Pret - Lunch',
          total_cents: 2400, currency: 'GBP', category: 'accommodation_and_meals', category_chosen: true,
          vat_treatment: 'domestic', vat_confirmed: true
        )
      end

      it 'knows where it’s uploaded to, until it’s deleted there' do
        uploaded = after(cmd(Expense::RecordUpload, destination: 'sheets', external_id: '9'), given: imported)
        project(uploaded)
        expect(row).to have_attributes(uploaded_to: ['sheets'])
        expect(row).to be_uploaded_to('sheets')

        deleted = after(cmd(Expense::RecordUploadDeletion, destination: 'sheets'), given: uploaded)
        project(deleted - uploaded)
        expect(row).to have_attributes(uploaded_to: [])
      end

      it 'knows where its upload failed, until one succeeds' do
        failed = after(cmd(Expense::RecordUploadFailure, destination: 'sheets', reason: 'Refused'), given: imported)
        project(failed)
        expect(row).to have_attributes(upload_failed_to: ['sheets'], uploaded_to: [])
        expect(row).to be_upload_failed_to('sheets')

        uploaded = after(cmd(Expense::RecordUpload, destination: 'sheets', external_id: '9'), given: failed)
        project(uploaded - failed)
        expect(row).to have_attributes(upload_failed_to: [], uploaded_to: ['sheets'])
      end

      it 'lists one without all it takes in review, its source’s category a suggestion' do
        project(after(import(vat_treatment: nil)))

        expect(row).to have_attributes(machine: include('reviewing'), category: 'accommodation_and_meals',
                                       category_chosen: false, vat_confirmed: false)
      end

      it 'takes a change at its source, filed again as it is there' do
        changed = after(import(description: 'Pret - Dinner', category: 'sundries', vat_treatment: 'no_vat', tax_amount_cents: 0),
                        given: imported)
        project(imported, changed - imported)

        expect(row).to have_attributes(machine: ['filed'], description: 'Pret - Dinner', total_cents: 2000,
                                       category: 'sundries', category_chosen: true, vat_treatment: 'no_vat')
      end
    end

    it 'shows what was filed' do
      filed = after(cmd(Expense::ChooseCategory, category: 'travel'), cmd(Expense::ConfirmVatTreatment, treatment: 'domestic'),
                    cmd(Expense::SaveExpense, description: 'Team lunch', net_price_cents: 3000, tax_amount_cents: 630,
                                              currency: 'EUR', incurred_on: Date.new(2026, 8, 10)),
                    given: drafted)
      project(drafted, filed - drafted)

      expect(row).to have_attributes(machine: ['filed'], description: 'Team lunch', total_cents: 3630,
                                     incurred_on: Date.new(2026, 8, 10))
    end

    it 'removes a discarded expense from the list and the search index' do
      project(drafted)
      expect(db[:expenses_search].where(expense_id:).count).to eq(1)

      discarded = after(cmd(Expense::DiscardExpense), given: drafted)
      project(discarded - drafted)

      expect(row).to be_nil
      expect(db[:expenses].where(expense_id:).count).to eq(0)
      expect(db[:expenses_search].where(expense_id:).count).to eq(0)
    end

    describe 'filtering' do
      around do |example|
        db.transaction(rollback: :always, auto_savepoint: true) do
          db[:expenses].delete
          example.run
        end
      end

      def expense(name, **columns)
        db[:expenses].insert(expense_id: name, description: name, machine: '["reviewing"]', created_at: Time.now,
                             updated_at: Time.now, **columns)
      end

      def ids(**filters) = ExpenseList.in_states(db, **filters).select_map(:expense_id).sort

      before do
        expense('suggested', category: 'travel', vat_treatment: 'domestic')
        expense('chosen', category: 'travel', category_chosen: true, vat_treatment: 'import', vat_confirmed: true)
        expense('blank')
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
        db[:expenses].where(expense_id: 'chosen').update(filing_country: 'NL')
        db[:expenses].where(expense_id: 'suggested').update(filing_country: 'GB')

        expect(ids(filing_countries: %w[NL])).to eq(%w[chosen])
        expect(ids(filing_countries: %w[GB NL], vat_statuses: %w[suggested])).to eq(%w[suggested])
        expect(ids(filing_countries: [])).to eq(%w[blank chosen suggested])
      end

      it 'counts and pages by them too' do
        expect(ExpenseList.counts(db, vat_statuses: %w[confirmed])).to include('reviewing' => 1)
        expect(ExpenseList.category_counts(db, vat_statuses: %w[suggested])).to eq('travel' => 1)
        expect(ExpenseList.page(db, category_statuses: %w[none]).then { [it[0].map(&:expense_id), it[1]] }).to eq([%w[blank], 1])
      end
    end
  end
end
