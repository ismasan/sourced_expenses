# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe Scanner do
    include Sourced::Testing::RSpec

    S = Expense::Scanning
    P = Prompts

    let(:store) { Sidereal.config['sourced.store'] }
    let(:file_store) { Sidereal.config['file_store'] }
    let(:expense_id) { SecureRandom.hex(16) }
    let(:today) { Date.new(2026, 8, 11) }
    let(:pdf) { file_store.put('lunch.pdf', "%PDF-1.4 #{SecureRandom.hex}") }

    let(:extraction) do
      {
        document_type: 'invoice', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0,
        tax_amount: 4.2, tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '9 Aug 2026',
        date: '2026-08-09', datetime: nil, vendor_name: 'Café Central', confidence: 'high', notes: nil,
        document_language: 'nl', supplier_country_code: 'NL', reverse_charge: false, payment_reference: 'R-1234'
      }
    end

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

    # The expense's history, in the store as the scanner loads it, and the
    # state event the scanner is handed: the last one.
    def at(*commands)
      history = decided(Expense, { expense_id: }, *commands)
      store.append(history)
      history.reverse.find { it.is_a?(Sourced::Machine::State) }
    end

    # Uploaded, and given a scanning slot.
    def upload(file_ref = pdf, content_type: 'application/pdf')
      [cmd(Expense::UploadDocument, filename: 'lunch.pdf', content_type:, file_ref:, filing_country: 'NL', reference_date: today),
       cmd(Expense::StartScan)]
    end

    # What the scanner appends for +event+: one message, or none.
    def dispatched(event)
      reacted(Scanner, event, expense_id:).tap { expect(it.size).to be <= 1 }
    end

    it 'prepares a PDF as it is, on entering scanning' do
      expect(dispatched(at(*upload))).to contain_exactly(
        an_object_having_attributes(class: S::CompletePreparation, payload: having_attributes(processed_file_ref: pdf, downsized: false))
      )
    end

    it 'shrinks a large image into a JPEG of its own' do
      big = Dir.mktmpdir do |dir|
        path = File.join(dir, 'big.png')
        # Over 1 MB, and cheap to make: a larger plasma takes seconds.
        system('magick', '-size', '500x500', 'plasma:', path, exception: true)
        File.open(path, 'rb') { file_store.put('big.png', it) }
      end
      expect(file_store.read(big).size).to be > Images::MAX_BYTES

      result = dispatched(at(*upload(big, content_type: 'image/png')))[0]
      expect(result).to be_a(S::CompletePreparation)
      expect(result.payload.downsized).to be(true)
      prepared = file_store.read(result.payload.processed_file_ref)
      expect(prepared.path).to end_with('data.jpg')
      expect(prepared.size).to be <= Images::MAX_BYTES
    end

    it 'extracts with the prompts, the reference date and the prepared file' do
      FAKE_LLM.answers[P::EXTRACTION_SCHEMA] = extraction

      event = at(*upload, cmd(S::CompletePreparation, processed_file_ref: pdf))
      expect(dispatched(event)[0]).to have_attributes(class: S::CompleteExtraction, payload: having_attributes(**extraction))

      call = FAKE_LLM.calls[0]
      expect(call[:file]).to eq(file_store.read(pdf).path)
      expect(call[:instructions]).to include('Today is 2026-08-11 (11 August 2026)')
      expect(call[:message]).to include('Please analyze this PDF document')
    end

    it "fails the step with the model's error" do
      FAKE_LLM.answers[P::EXTRACTION_SCHEMA] = LLM::Error.new('OpenAI is rate limiting requests')

      event = at(*upload, cmd(S::CompletePreparation, processed_file_ref: pdf))
      expect(dispatched(event)[0]).to have_attributes(class: S::FailExtraction, payload: having_attributes(reason: 'OpenAI is rate limiting requests'))
    end

    it "fails the step when the answer doesn't fit the command" do
      FAKE_LLM.answers[P::DOCUMENT_VERIFICATION_SCHEMA] = { is_invoice_or_receipt: 'maybe', explanation: 'hm' }

      event = at(*upload, cmd(S::CompletePreparation, processed_file_ref: pdf),
                 cmd(S::CompleteExtraction, **extraction, confidence: 'low'))
      expect(event).to be_a(S::Verifying)
      expect(dispatched(event)[0]).to have_attributes(class: S::FailVerification, payload: having_attributes(reason: include('is_invoice_or_receipt')))
    end

    it 'rechecks a suspect date, told the first reading' do
      FAKE_LLM.answers[P::DATE_RECHECK_SCHEMA] = {
        date_as_printed: '09/03/2026', date: '2026-08-09', reasoning: 'The 3 is a smudged 8',
        candidates: [{ 'date' => '2026-08-09', 'reading' => 'smudged 8', 'in_the_future' => false }]
      }

      event = at(*upload, cmd(S::CompletePreparation, processed_file_ref: pdf),
                 cmd(S::CompleteExtraction, **extraction, date_as_printed: '09/03/2026', date: '2026-03-09'))
      expect(dispatched(event)[0]).to be_a(S::CompleteDateRecheck)
      expect(FAKE_LLM.calls[0][:instructions]).to include('"09/03/2026"', 'read it as 2026-03-09', '155 days before today')
    end

    it 'cleans the text without the file' do
      FAKE_LLM.answers[P::CLEANUP_SCHEMA] = { description: 'Café Central — Lunch', tax_description: nil }

      event = at(*upload, cmd(S::CompletePreparation, processed_file_ref: pdf), cmd(S::CompleteExtraction, **extraction))
      expect(event).to be_a(S::Cleaning)
      expect(dispatched(event)[0].payload).to have_attributes(description: 'Café Central — Lunch', tax_description: 'BTW 21%')
      expect(FAKE_LLM.calls[0][:file]).to be_nil
    end

    describe 'a state the expense has since left' do
      # The history after +commands+, and then +later+, in the store.
      def left(commands, *later)
        before = decided(Expense, { expense_id: }, *commands)
        store.append(before)
        store.append(decided(Expense, { expense_id: }, *later, given: before) - before)
        before.reverse.find { it.is_a?(Sourced::Machine::State) }
      end

      it 'does nothing once discarded' do
        expect(dispatched(left(upload, cmd(Expense::DiscardDocument)))).to be_empty
      end

      it 'does nothing once the step is done' do
        expect(dispatched(left(upload, cmd(S::CompletePreparation, processed_file_ref: pdf)))).to be_empty
      end

      it 'does nothing once timed out' do
        expect(dispatched(left(upload, cmd(Expense::TimeOutScan)))).to be_empty
      end
    end
  end
end
