# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe Ledger do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.hex(16) }
    let(:date) { Date.new(2025, 10, 24) }

    # Each example on an empty ledger, rolled back after.
    around do |example|
      db.transaction(rollback: :always, auto_savepoint: true) do
        db[:ledger].delete
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

    def converted(id = expense_id, reporting_cents: 2113, amount_cents: 2420, **rest)
      cmd(Expense::RecordConversion, id, currency: 'EUR', amount_cents:, incurred_on: date, reporting_currency: 'GBP',
                                         reporting_cents:, rate: 0.8731, rate_date: date, **rest)
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
        with_reactor(Ledger, expense_id: id).given(message).then! { nil }
      end
    end

    def row(id = expense_id) = db[:ledger].where(expense_id: id).first

    it 'has nothing for an expense not filed yet' do
      project(*reviewing)

      expect(row).to be_nil
    end

    it 'records a filed expense, its conversion to come' do
      project(*reviewing, save)

      expect(row).to include(incurred_on: date, currency: 'EUR', amount_cents: 2420, reporting_currency: nil, reporting_cents: nil)
    end

    it 'takes the conversion once recorded' do
      project(*reviewing, save, converted)

      expect(row).to include(reporting_currency: 'GBP', reporting_cents: 2113)
    end

    it 'clears the conversion when a correction changes the total, until it is converted again' do
      project(*reviewing, save, converted, save(net_price_cents: 3000))
      expect(row).to include(amount_cents: 3420, reporting_currency: nil, reporting_cents: nil)
    end

    it 'keeps it when a correction leaves the total alone' do
      project(*reviewing, save, converted, save(description: 'Team lunch'))

      expect(row).to include(description: 'Team lunch', reporting_cents: 2113)
    end

    it 'deletes every row when its group is reset, to build them again' do
      project(*reviewing, save)
      expect(row).not_to be_nil

      Ledger.on_reset

      expect(db[:ledger].count).to eq(0)
    end

    it 'drops a voided expense' do
      project(*reviewing, save, converted, cmd(Expense::VoidExpense, reason: 'Duplicate'))

      expect(row).to be_nil
    end

    describe '.months' do
      it 'totals every month from the first expense to the one given, oldest first, empty ones too' do
        a, b, c, earlier = Array.new(4) { SecureRandom.hex(16) }
        project(*reviewing(a), save(a), converted(a), id: a)
        project(*reviewing(b), save(b, currency: 'GBP', net_price_cents: 1000, tax_amount_cents: 0), id: b)
        project(*reviewing(c), save(c, incurred_on: Date.new(2025, 8, 3)), id: c)
        project(*reviewing(earlier), save(earlier, currency: 'GBP', incurred_on: Date.new(2025, 7, 31)), id: earlier)

        months = Ledger.months(db, 'GBP', date: Date.new(2025, 10, 31))

        expect(months.map { [it.from, it.to, it.cents, it.expenses, it.unconverted] }).to eq([
          [Date.new(2025, 7, 1), Date.new(2025, 7, 31), 2420, 1, 0],
          [Date.new(2025, 8, 1), Date.new(2025, 8, 31), 0, 1, 1],
          [Date.new(2025, 9, 1), Date.new(2025, 9, 30), 0, 0, 0],
          [Date.new(2025, 10, 1), Date.new(2025, 10, 31), 3113, 2, 0]
        ])
        expect(months).to all(have_attributes(currency: 'GBP'))
      end

      it 'runs to the last expense, when dated after the day given' do
        project(*reviewing, save(currency: 'GBP', incurred_on: Date.new(2025, 12, 2)))

        expect(Ledger.months(db, 'GBP', date: Date.new(2025, 10, 31)).map(&:from)).to eq([Date.new(2025, 12, 1)])
      end

      it "is just the day given's month, empty, with nothing filed" do
        expect(Ledger.months(db, 'GBP', date: Date.new(2025, 10, 31))).to eq([
          Ledger::Total.new(currency: 'GBP', from: Date.new(2025, 10, 1), to: Date.new(2025, 10, 31), cents: 0, expenses: 0,
                            unconverted: 0)
        ])
      end
    end

    describe '.month' do
      it "totals a month's expenses in a currency, by their own dates, saying how many aren't converted yet" do
        a, b, c, d, other_month = Array.new(5) { SecureRandom.hex(16) }
        project(*reviewing(a), save(a), converted(a), id: a)
        project(*reviewing(b), save(b, currency: 'GBP', net_price_cents: 1000, tax_amount_cents: 0), id: b)
        project(*reviewing(c), save(c), id: c)
        project(*reviewing(d), save(d), converted(d, reporting_currency: 'USD', reporting_cents: 2810), id: d)
        project(*reviewing(other_month), save(other_month, incurred_on: Date.new(2025, 11, 1)),
                converted(other_month, incurred_on: Date.new(2025, 11, 1)), id: other_month)

        expect(Ledger.month(db, 'GBP', Date.new(2025, 10, 31))).to eq(
          Ledger::Total.new(currency: 'GBP', from: Date.new(2025, 10, 1), to: Date.new(2025, 10, 31), cents: 3113, expenses: 4,
                            unconverted: 2)
        )
        expect(Ledger.month(db, 'USD', Date.new(2025, 10, 31))).to have_attributes(cents: 2810, unconverted: 3)
      end

      it 'totals any range, open at either end' do
        a, b, outside = Array.new(3) { SecureRandom.hex(16) }
        project(*reviewing(a), save(a), converted(a), id: a)
        project(*reviewing(b), save(b, currency: 'GBP', net_price_cents: 1000, tax_amount_cents: 0), id: b)
        project(*reviewing(outside), save(outside, incurred_on: Date.new(2025, 11, 1)), id: outside)

        expect(Ledger.total(db, 'GBP', from: Date.new(2025, 10, 20), to: Date.new(2025, 10, 31))).to have_attributes(cents: 3113, expenses: 2)
        expect(Ledger.total(db, 'GBP', from: Date.new(2025, 10, 20))).to have_attributes(expenses: 3)
        expect(Ledger.total(db, 'GBP', to: Date.new(2025, 10, 31))).to have_attributes(expenses: 2)
      end

      it 'is empty for a month with nothing filed' do
        expect(Ledger.month(db, 'GBP', Date.new(2020, 2, 10))).to eq(
          Ledger::Total.new(currency: 'GBP', from: Date.new(2020, 2, 1), to: Date.new(2020, 2, 29), cents: 0, expenses: 0,
                            unconverted: 0)
        )
      end
    end
  end
end
