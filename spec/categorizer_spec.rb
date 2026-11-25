# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe Categorizer do
    include Sourced::Testing::RSpec

    let(:store) { Sidereal.config['sourced.store'] }
    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.hex(16) }
    let(:date) { Date.new(2025, 10, 24) }

    let(:extraction) do
      { document_type: 'receipt', description: 'Uber - Trip', total_amount: 18.5, net_amount: nil, tax_amount: nil,
        tax_description: nil, currency: 'GBP', date_as_printed: '24 Oct 2025', date: '2025-10-24', vendor_name: 'Uber',
        confidence: 'high', supplier_country_code: 'GB', reverse_charge: false }
    end

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

    def save(**form)
      cmd(Expense::SaveExpense, description: 'Uber - Trip', net_price_cents: 1850, tax_amount_cents: 0, currency: 'GBP',
                          incurred_on: date, supplier_country_code: 'GB', **form)
    end

    let(:upload) do
      cmd(Expense::UploadDocument, filename: 'uber.pdf', content_type: 'application/pdf', file_ref: 'f1', filing_country: 'GB',
                             reference_date: date)
    end

    # Uploaded, scanned and ready to review.
    let(:reviewing) do
      [upload, cmd(Expense::StartScan),
       cmd(Expense::Scanning::CompletePreparation, processed_file_ref: 'f1'),
       cmd(Expense::Scanning::CompleteExtraction, **extraction),
       cmd(Expense::Scanning::CompleteCleanup, description: 'Uber - Trip', tax_description: nil)]
    end

    # The history after +commands+, in the store as the categorizer loads it.
    def history(*commands, given: [])
      decided(Expense, { expense_id: }, *commands, given:).tap { store.append(it - given) }
    end

    def last(klass, messages) = messages.reverse.find { it.is_a?(klass) }

    # What the categorizer dispatches for +event+: one message, or none.
    def dispatched(event)
      reacted(Categorizer, event, expense_id:).tap { expect(it.size).to be <= 1 }
    end

    def payload(message) = message.payload.to_h.except(:expense_id)

    # The suggestion for +event+, recorded on the expense.
    def suggest(event, given:) = history(cmd(Expense::SuggestCategory, **payload(dispatched(event).first)), given:)

    it 'suggests a category once the scan is done, from what it read' do
      FAKE_LLM.category = { category: 'travel', probability: 0.93 }
      scanned = history(*reviewing)

      expect(dispatched(last(Expense::Scanning::Scanned, scanned)).map { [it.class, payload(it)] }).to eq([
        [Expense::SuggestCategory, { category: 'travel', probability: 0.93, description: 'Uber - Trip' }]
      ])
      expect(FAKE_LLM.categorized).to eq([{ filename: 'uber.pdf', description: 'Uber - Trip', vendor: 'Uber', tax_description: nil,
                                            supplier_country: 'GB', total: '18.50 GBP' }])
    end

    it 'reports a model that fails' do
      FAKE_LLM.category = LLM::Error.new('OpenAI is rate limiting requests')
      scanned = history(*reviewing)

      expect(dispatched(last(Expense::Scanning::Scanned, scanned)).map { [it.class, payload(it)] }).to eq([
        [Expense::FailCategorization, { description: 'Uber - Trip', reason: 'OpenAI is rate limiting requests' }]
      ])
    end

    it 'never suggests over a category a person chose' do
      scanned = history(*reviewing)
      history(cmd(Expense::ChooseCategory, category: 'motor_expenses'), given: scanned)

      expect(dispatched(last(Expense::Scanning::Scanned, scanned))).to be_empty
      expect(FAKE_LLM.categorized).to be_empty
    end

    # A new group catching up on a store with expenses in it already.
    describe 'catching up on existing expenses' do
      it 'suggests for one still in review' do
        scanned = history(*reviewing)

        expect(dispatched(last(Expense::Scanning::Scanned, scanned)).map(&:class)).to eq([Expense::SuggestCategory])
      end

      it 'tries again one whose categorization failed' do
        scanned = history(*reviewing)
        history(cmd(Expense::FailCategorization, description: 'Uber - Trip', reason: 'Down'), given: scanned)

        expect(dispatched(last(Expense::Scanning::Scanned, scanned)).map(&:class)).to eq([Expense::SuggestCategory])
      end

      it 'skips a filed expense' do
        scanned = history(*reviewing)
        history(cmd(Expense::ConfirmVatTreatment, treatment: 'domestic'), cmd(Expense::ChooseCategory, category: 'travel'),
                save, given: scanned)

        expect(dispatched(last(Expense::Scanning::Scanned, scanned))).to be_empty
        expect(FAKE_LLM.categorized).to be_empty
      end

      it 'skips a discarded expense' do
        scanned = history(*reviewing)
        history(cmd(Expense::DiscardDocument), given: scanned)

        expect(dispatched(last(Expense::Scanning::Scanned, scanned))).to be_empty
        expect(FAKE_LLM.categorized).to be_empty
      end

      it 'skips one it has a suggestion for already (a reset group)' do
        scanned = history(*reviewing)
        suggest(last(Expense::Scanning::Scanned, scanned), given: scanned)
        FAKE_LLM.reset!

        expect(dispatched(last(Expense::Scanning::Scanned, scanned))).to be_empty
        expect(FAKE_LLM.categorized).to be_empty
      end
    end

    describe 'the expense' do
      def doc(messages) = Expense.new(expense_id:).tap { it.evolve(messages) }.context

      it 'takes the suggestion in review, until a person chooses' do
        scanned = history(*reviewing)
        suggested = history(cmd(Expense::SuggestCategory, category: 'travel', probability: 0.9, description: 'Uber - Trip'), given: scanned)
        resuggested = history(cmd(Expense::SuggestCategory, category: 'motor_expenses', probability: 0.6, description: 'Uber'),
                              given: suggested)

        expect(doc(suggested)).to have_attributes(category: 'travel', category_chosen?: false)
        expect(doc(resuggested)).to have_attributes(category: 'motor_expenses', category_chosen?: false)
      end

      it 'keeps a person’s choice over any later suggestion' do
        scanned = history(*reviewing)
        later = history(cmd(Expense::ChooseCategory, category: 'travel'),
                        cmd(Expense::SuggestCategory, category: 'general', probability: 0.4, description: 'Uber - Trip'), given: scanned)

        expect(later - scanned).to all(satisfy { !it.is_a?(Expense::CategorySuggested) })
        expect(doc(later)).to have_attributes(category: 'travel', category_chosen?: true)
      end

      it 'refuses a category that is not on the list' do
        expect(cmd(Expense::ChooseCategory, category: 'snacks')).not_to be_valid
      end

      it 'lists the category, the suggestion until a person chooses' do
        scanned = history(*reviewing)
        suggested = history(cmd(Expense::SuggestCategory, category: 'travel', probability: 0.9, description: 'Uber - Trip'), given: scanned)
        chosen = history(cmd(Expense::ChooseCategory, category: 'motor_expenses'),
                         cmd(Expense::SuggestCategory, category: 'general', probability: 0.4, description: 'Other'), given: suggested)
        project = ->(messages) { messages.reduce(with_reactor(Submissions, expense_id:)) { |r, m| r.given(m) }.then! { nil } }
        row = -> { Submissions.recent(db, limit: 1000).find { it.expense_id == expense_id } }

        project.(suggested)
        expect(row.()).to have_attributes(category: 'travel', category_chosen: false)

        project.(chosen - suggested)
        expect(row.()).to have_attributes(category: 'motor_expenses', category_chosen: true)
      end
    end
  end
end
