# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe CurrencyConverter do
    include Sourced::Testing::RSpec

    E = Expense

    let(:store) { Sidereal.config['sourced.store'] }
    let(:expense_id) { SecureRandom.hex(16) }
    let(:date) { Date.new(2025, 10, 24) }

    let(:extraction) do
      { document_type: 'invoice', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0,
        tax_amount: 4.2, tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '24 Oct 2025', date: '2025-10-24',
        vendor_name: 'Café Central', confidence: 'high', supplier_country_code: 'NL', reverse_charge: false }
    end

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

    def save(**form)
      cmd(E::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR',
                          incurred_on: date, supplier_country_code: 'NL', **form)
    end

    # Uploaded, scanned and reviewed: ready to file.
    let(:reviewing) do
      [cmd(E::UploadDocument, filename: 'lunch.pdf', content_type: 'application/pdf', file_ref: 'f1', filing_country: 'NL',
                              reference_date: date),
       cmd(E::StartScan),
       cmd(E::Scanning::CompletePreparation, processed_file_ref: 'f1'),
       cmd(E::Scanning::CompleteExtraction, **extraction),
       cmd(E::Scanning::CompleteCleanup, description: 'Café Central - Lunch', tax_description: 'BTW 21%'),
       cmd(E::ConfirmVatTreatment, treatment: 'domestic'),
       cmd(E::ChooseCategory, category: 'accommodation_and_meals')]
    end

    # The history after +commands+, in the store as the converter loads it.
    def history(*commands, given: [])
      decided(Expense, { expense_id: }, *commands, given:).tap { store.append(it - given) }
    end

    def last_filed(messages) = messages.reverse.find { it.is_a?(E::ExpenseFiled) }

    # What the converter dispatches for +event+: one message, or none.
    def dispatched(event)
      reacted(CurrencyConverter, event, expense_id:).tap { expect(it.size).to be <= 1 }
    end

    def payload(message) = message.payload.to_h.except(:expense_id)

    it 'converts the filed total, VAT included, at the rate on its date' do
      FAKE_RATES.rates['EUR'] = 0.8731
      filed = history(*reviewing, save)

      expect(dispatched(last_filed(filed)).map { [it.class, payload(it)] }).to eq([
        [E::RecordConversion, { currency: 'EUR', amount_cents: 2420, incurred_on: date, reporting_currency: 'GBP', reporting_cents: 2113,
                                 rate: 0.8731, rate_date: date }]
      ])
      expect(FAKE_RATES.calls).to eq([{ from: 'EUR', to: 'GBP', on: date }])
    end

    it 'leaves an expense in the reporting currency alone' do
      filed = history(*reviewing, save(currency: 'GBP'))

      expect(dispatched(last_filed(filed))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'reports a rate it cannot get' do
      filed = history(*reviewing, save(currency: 'XOF'))

      expect(dispatched(last_filed(filed)).map { [it.class, it.payload.reason] }).to eq([
        [E::FailConversion, 'No exchange rate from XOF to GBP']
      ])
    end

    it 'skips a filing since corrected, without asking for a rate' do
      first = history(*reviewing, save)
      history(save(net_price_cents: 3000), given: first)

      expect(dispatched(last_filed(first))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'skips a filing since voided' do
      first = history(*reviewing, save)
      history(cmd(E::VoidExpense, reason: 'Duplicate'), given: first)

      expect(dispatched(last_filed(first))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'converts again a correction that changes the total' do
      FAKE_RATES.rates['EUR'] = 0.8731
      filed = history(*reviewing, save)
      converted = history(cmd(E::RecordConversion, **payload(dispatched(last_filed(filed)).first)), given: filed)
      corrected = history(save(net_price_cents: 3000), given: converted)

      expect(dispatched(last_filed(corrected)).map { payload(it).slice(:amount_cents, :reporting_cents) }).to eq([{ amount_cents: 3420, reporting_cents: 2986 }])
    end

    it 'skips a correction that leaves the converted total alone' do
      FAKE_RATES.rates['EUR'] = 0.8731
      filed = history(*reviewing, save)
      converted = history(cmd(E::RecordConversion, **payload(dispatched(last_filed(filed)).first)), given: filed)
      FAKE_RATES.reset!
      corrected = history(save(description: 'Team lunch'), given: converted)

      expect(dispatched(last_filed(corrected))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'tries again a filing whose conversion failed' do
      FAKE_RATES.rates['EUR'] = 0.8731
      filed = history(*reviewing, save)
      history(cmd(E::FailConversion, currency: 'EUR', amount_cents: 2420, incurred_on: date, reporting_currency: 'GBP', reason: 'Down'), given: filed)

      expect(dispatched(last_filed(filed)).map(&:class)).to eq([E::RecordConversion])
    end

    it 'skips a filing already converted' do
      FAKE_RATES.rates['EUR'] = 0.8731
      filed = history(*reviewing, save)
      history(cmd(E::RecordConversion, **payload(dispatched(last_filed(filed)).first)), given: filed)
      FAKE_RATES.reset!

      expect(dispatched(last_filed(filed))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'converts again, to the reporting currency, one converted to another before it changed' do
      FAKE_RATES.rates['EUR'] = 1.1612
      filed = history(*reviewing, save)
      to_usd = history(cmd(E::RecordConversion, currency: 'EUR', amount_cents: 2420, incurred_on: date, reporting_currency: 'USD',
                                                reporting_cents: 2810, rate: 1.1612, rate_date: date), given: filed)
      recorded = to_usd.last
      FAKE_RATES.rates['EUR'] = 0.8731

      expect(dispatched(last_filed(filed))).to be_empty
      expect(dispatched(recorded).map { payload(it).slice(:reporting_currency, :reporting_cents) }).to eq([
        { reporting_currency: 'GBP', reporting_cents: 2113 }
      ])
    end

    it 'leaves alone a conversion to the reporting currency' do
      FAKE_RATES.rates['EUR'] = 0.8731
      filed = history(*reviewing, save)
      converted = history(cmd(E::RecordConversion, **payload(dispatched(last_filed(filed)).first)), given: filed)
      FAKE_RATES.reset!

      expect(dispatched(converted.last)).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    describe 'the expense' do
      let(:converted) do
        { currency: 'EUR', amount_cents: 2420, incurred_on: date, reporting_currency: 'GBP', reporting_cents: 2113, rate: 0.8731,
          rate_date: date }
      end

      def expense(history)
        Expense.new(expense_id:).tap { it.evolve(history) }
      end

      it 'records the conversion' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordConversion, **converted))

        expect(after.last).to be_a(E::ConversionRecorded)
        expect(expense(after).context.converted).to eq(converted)
      end

      it 'records it once' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordConversion, **converted), cmd(E::RecordConversion, **converted))

        expect(after.grep(E::ConversionRecorded).size).to eq(1)
      end

      it 'drops one for an amount since corrected, and forgets the old one on correcting' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordConversion, **converted), save(net_price_cents: 3000),
                        cmd(E::RecordConversion, **converted))

        expect(after.grep(E::ConversionRecorded).size).to eq(1)
        expect(expense(after).context.converted).to be_nil
      end

      it 'keeps it when a correction leaves the total alone' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordConversion, **converted), save(description: 'Team lunch'))

        expect(expense(after).context.converted).to eq(converted)
      end

      it 'records a failure, and forgets it once converted' do
        failure = converted.slice(:currency, :amount_cents, :incurred_on, :reporting_currency)
                           .merge(reason: 'The exchange rate service could not be reached')
        failed = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::FailConversion, **failure))
        expect(expense(failed).context.conversion_failure).to eq(failure)

        after = decided(Expense, { expense_id: }, cmd(E::RecordConversion, **converted), given: failed)
        expect(expense(after).context).to have_attributes(converted:, conversion_failure: nil)
      end

      it 'takes no conversion once voided' do
        voided = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::VoidExpense, reason: 'Duplicate'))

        expect(Expense.new(expense_id:).tap { it.evolve(voided) }.handles_command?(cmd(E::RecordConversion, **converted))).to be(false)
      end
    end
  end
end
