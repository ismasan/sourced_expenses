# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe UsdLedger do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.uuid }
    let(:date) { Date.new(2025, 10, 24) }

    # Each example on an empty ledger, rolled back after.
    around do |example|
      db.transaction(rollback: :always, auto_savepoint: true) do
        db[:usd_ledger].delete
        example.run
      end
    end

    let(:extraction) do
      { document_type: 'invoice', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0,
        tax_amount: 4.2, tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '24 Oct 2025', date: '2025-10-24',
        vendor_name: 'Café Central', confidence: 'high', supplier_country_code: 'NL', reverse_charge: false }
    end

    def cmd(klass, id = expense_id, **payload) = klass.new(payload: { expense_id: id, **payload })

    def save(id = expense_id, **form)
      cmd(Expense::SaveExpense, id, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR',
                                    incurred_on: date, supplier_country_code: 'NL', **form)
    end

    def usd(id = expense_id, usd_cents: 2810, amount_cents: 2420, **rest)
      cmd(Expense::RecordUsdAmount, id, currency: 'EUR', amount_cents:, incurred_on: date, usd_cents:, rate: 1.1612,
                                        rate_date: date, **rest)
    end

    # Uploaded, scanned and ready to review.
    def reviewing(id = expense_id)
      [cmd(Expense::UploadDocument, id, filename: 'lunch.pdf', content_type: 'application/pdf', file_ref: 'f1',
                                        filing_country: 'NL', reference_date: date),
       cmd(Expense::Scanning::CompletePreparation, id, processed_file_ref: 'f1'),
       cmd(Expense::Scanning::CompleteExtraction, id, **extraction),
       cmd(Expense::Scanning::CompleteCleanup, id, description: 'Café Central - Lunch', tax_description: 'BTW 21%')]
    end

    # Projects the history +commands+ make for expense +id+, one message at a
    # time, as separate batches would.
    def project(*commands, id: expense_id)
      decided(Expense, { expense_id: id }, *commands).each do |message|
        with_reactor(UsdLedger, expense_id: id).given(message).then! { nil }
      end
    end

    def row(id = expense_id) = db[:usd_ledger].where(expense_id: id).first

    it 'has nothing for an expense not filed yet' do
      project(*reviewing)

      expect(row).to be_nil
    end

    it 'records a filed expense, its USD amount to come' do
      project(*reviewing, save)

      expect(row).to include(incurred_on: date, currency: 'EUR', amount_cents: 2420, usd_cents: nil)
    end

    it 'takes the USD amount once recorded' do
      project(*reviewing, save, usd)

      expect(row).to include(usd_cents: 2810)
    end

    it 'counts an expense in USD as it is' do
      project(*reviewing, save(currency: 'USD'))

      expect(row).to include(currency: 'USD', usd_cents: 2420)
    end

    it 'clears the USD amount when a correction changes the total, until it is converted again' do
      project(*reviewing, save, usd, save(net_price_cents: 3000))
      expect(row).to include(amount_cents: 3420, usd_cents: nil)
    end

    it 'keeps it when a correction leaves the total alone' do
      project(*reviewing, save, usd, save(description: 'Team lunch'))

      expect(row).to include(description: 'Team lunch', usd_cents: 2810)
    end

    it 'drops a voided expense' do
      project(*reviewing, save, usd, cmd(Expense::VoidExpense, reason: 'Duplicate'))

      expect(row).to be_nil
    end

    describe '.month' do
      it "totals a month's expenses in USD, by their own dates, saying how many aren't converted yet" do
        a, b, c, other_month = Array.new(4) { SecureRandom.uuid }
        project(*reviewing(a), save(a), usd(a), id: a)
        project(*reviewing(b), save(b, currency: 'USD', net_price_cents: 1000, tax_amount_cents: 0), id: b)
        project(*reviewing(c), save(c), id: c)
        project(*reviewing(other_month), save(other_month, incurred_on: Date.new(2025, 11, 1)), usd(other_month, incurred_on: Date.new(2025, 11, 1)),
                id: other_month)

        expect(UsdLedger.month(db, Date.new(2025, 10, 31))).to eq(
          UsdLedger::Month.new(first_day: Date.new(2025, 10, 1), usd_cents: 3810, expenses: 3, unconverted: 1)
        )
      end

      it 'is empty for a month with nothing filed' do
        expect(UsdLedger.month(db, Date.new(2020, 2, 10))).to eq(
          UsdLedger::Month.new(first_day: Date.new(2020, 2, 1), usd_cents: 0, expenses: 0, unconverted: 0)
        )
      end
    end
  end
end
