# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe USDConverter do
    include Sourced::Testing::RSpec

    E = Expense

    let(:store) { Sidereal.config['sourced.store'] }
    let(:expense_id) { SecureRandom.uuid }
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

    # Uploaded, scanned and ready to review.
    let(:reviewing) do
      [cmd(E::UploadDocument, filename: 'lunch.pdf', content_type: 'application/pdf', file_ref: 'f1', filing_country: 'NL',
                              reference_date: date),
       cmd(E::Scanning::CompletePreparation, processed_file_ref: 'f1'),
       cmd(E::Scanning::CompleteExtraction, **extraction),
       cmd(E::Scanning::CompleteCleanup, description: 'Café Central - Lunch', tax_description: 'BTW 21%')]
    end

    # The history after +commands+, in the store as the converter loads it.
    def history(*commands, given: [])
      decided(Expense, { expense_id: }, *commands, given:).tap { store.append(it - given) }
    end

    def last_filed(messages) = messages.reverse.find { it.is_a?(E::ExpenseFiled) }

    # What the converter dispatches for +event+: one message, or none.
    def dispatched(event)
      reacted(USDConverter, event, expense_id:).tap { expect(it.size).to be <= 1 }
    end

    def payload(message) = message.payload.to_h.except(:expense_id)

    it 'converts the filed total, VAT included, at the rate on its date' do
      FAKE_RATES.rates['EUR'] = 1.1612
      filed = history(*reviewing, save)

      expect(dispatched(last_filed(filed)).map { [it.class, payload(it)] }).to eq([
        [E::RecordUSDAmount, { currency: 'EUR', amount_cents: 2420, incurred_on: date, usd_cents: 2810, rate: 1.1612, rate_date: date }]
      ])
      expect(FAKE_RATES.calls).to eq([{ from: 'EUR', to: 'USD', on: date }])
    end

    it 'leaves an expense in USD alone' do
      filed = history(*reviewing, save(currency: 'USD'))

      expect(dispatched(last_filed(filed))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'reports a rate it cannot get' do
      filed = history(*reviewing, save(currency: 'XOF'))

      expect(dispatched(last_filed(filed)).map { [it.class, it.payload.reason] }).to eq([
        [E::FailUSDConversion, 'No exchange rate from XOF to USD']
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
      FAKE_RATES.rates['EUR'] = 1.1612
      filed = history(*reviewing, save)
      converted = history(cmd(E::RecordUSDAmount, **payload(dispatched(last_filed(filed)).first)), given: filed)
      corrected = history(save(net_price_cents: 3000), given: converted)

      expect(dispatched(last_filed(corrected)).map { payload(it).slice(:amount_cents, :usd_cents) }).to eq([{ amount_cents: 3420, usd_cents: 3971 }])
    end

    it 'skips a correction that leaves the converted total alone' do
      FAKE_RATES.rates['EUR'] = 1.1612
      filed = history(*reviewing, save)
      converted = history(cmd(E::RecordUSDAmount, **payload(dispatched(last_filed(filed)).first)), given: filed)
      FAKE_RATES.reset!
      corrected = history(save(description: 'Team lunch'), given: converted)

      expect(dispatched(last_filed(corrected))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    it 'tries again a filing whose conversion failed' do
      FAKE_RATES.rates['EUR'] = 1.1612
      filed = history(*reviewing, save)
      history(cmd(E::FailUSDConversion, currency: 'EUR', amount_cents: 2420, incurred_on: date, reason: 'Down'), given: filed)

      expect(dispatched(last_filed(filed)).map(&:class)).to eq([E::RecordUSDAmount])
    end

    it 'skips a filing already converted' do
      FAKE_RATES.rates['EUR'] = 1.1612
      filed = history(*reviewing, save)
      history(cmd(E::RecordUSDAmount, **payload(dispatched(last_filed(filed)).first)), given: filed)
      FAKE_RATES.reset!

      expect(dispatched(last_filed(filed))).to be_empty
      expect(FAKE_RATES.calls).to be_empty
    end

    describe 'the expense' do
      let(:usd) { { currency: 'EUR', amount_cents: 2420, incurred_on: date, usd_cents: 2810, rate: 1.1612, rate_date: date } }

      def expense(history)
        Expense.new(expense_id:).tap { it.evolve(history) }
      end

      it 'records the USD amount' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordUSDAmount, **usd))

        expect(after.last).to be_a(E::USDAmountRecorded)
        expect(expense(after).context.usd).to eq(usd)
      end

      it 'records it once' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordUSDAmount, **usd), cmd(E::RecordUSDAmount, **usd))

        expect(after.grep(E::USDAmountRecorded).size).to eq(1)
      end

      it 'drops one for an amount since corrected, and forgets the old one on correcting' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordUSDAmount, **usd), save(net_price_cents: 3000),
                        cmd(E::RecordUSDAmount, **usd))

        expect(after.grep(E::USDAmountRecorded).size).to eq(1)
        expect(expense(after).context.usd).to be_nil
      end

      it 'keeps it when a correction leaves the total alone' do
        after = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::RecordUSDAmount, **usd), save(description: 'Team lunch'))

        expect(expense(after).context.usd).to eq(usd)
      end

      it 'records a failure, and forgets it once converted' do
        failure = usd.slice(:currency, :amount_cents, :incurred_on).merge(reason: 'The exchange rate service could not be reached')
        failed = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::FailUSDConversion, **failure))
        expect(expense(failed).context.usd_failure).to eq(failure)

        converted = decided(Expense, { expense_id: }, cmd(E::RecordUSDAmount, **usd), given: failed)
        expect(expense(converted).context).to have_attributes(usd:, usd_failure: nil)
      end

      it 'takes no USD amount once voided' do
        voided = decided(Expense, { expense_id: }, *reviewing, save, cmd(E::VoidExpense, reason: 'Duplicate'))

        expect(Expense.new(expense_id:).tap { it.evolve(voided) }.handles_command?(cmd(E::RecordUSDAmount, **usd))).to be(false)
      end
    end
  end
end
