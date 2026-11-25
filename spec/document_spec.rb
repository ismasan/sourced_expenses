# frozen_string_literal: true

require 'sourced/testing/rspec'

# Inside Document, so its commands, states and parts read by their own names.
module Expenses
  class Document
    RSpec.describe Document do
      include Sourced::Testing::RSpec

      let(:document_id) { '3a1b2c4d5e6f4a7b8c9d0e1f2a3b4c5d' }
      let(:today) { Date.new(2026, 8, 11) }

      def cmd(klass, **payload) = klass.new(payload: { document_id:, **payload })
      def history(*commands, given: []) = decided(Document, { document_id: }, *commands, given:)
      def document(history) = Document.new(document_id:).tap { it.evolve(history) }
      def value(history) = document(history).machine.value
      def scanning(state) = { Scanning::State => state }

      # A clean extraction: plausible, with a spelled-out recent date.
      def extraction(**overrides)
        {
          document_type: 'invoice', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0,
          tax_amount: 4.2, tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '9 Aug 2026',
          date: '2026-08-09', datetime: nil, vendor_name: 'Café Central', confidence: 'high', notes: nil,
          document_language: 'nl', supplier_country_code: 'NL', reverse_charge: false, payment_reference: 'R-1234',
          **overrides
        }
      end

      let(:upload) do
        cmd(UploadDocument, filename: 'lunch.jpg', content_type: 'image/jpeg', file_ref: 'uploads/lunch.jpg',
                            filing_country: 'NL', reference_date: today)
      end
      let(:queued) { history(upload) }
      let(:uploaded) { history(cmd(StartScan), given: queued) }

      # What the machine dispatches claiming the last state event in +history+
      # (its entry and exit actions, and timers), as the runtime would.
      def dispatched_entering(history)
        *before, entered = history
        messages = nil
        before.reduce(with_reactor(Document, document_id:)) { |gwt, msg| gwt.given(msg) }
              .when(entered).then { |result| messages = result.messages }
        messages
      end

      let(:extracting) do
        history(cmd(Scanning::CompletePreparation, processed_file_ref: 'tmp/lunch-small.jpg', downsized: true), given: uploaded)
      end

      def extracted(**overrides) = history(cmd(Scanning::CompleteExtraction, **extraction(**overrides)), given: extracting)

      def scanned(**overrides)
        history(cmd(Scanning::CompleteCleanup, description: 'Café Central - Lunch', tax_description: 'BTW 21%'),
                given: extracted(**overrides))
      end

      def drafts(history) = dispatched_entering(history).grep(Expense::DraftExpenseFromDocument)

      it 'is a valid chart' do
        expect(Expenses.machines.map(&:to_h)).to all(include(:states))
      end

      describe 'the scan queue' do
        let(:job) { WorkQueue.item_id(StartScan, document_id:) }

        it 'waits in queued on upload, enqueuing its scan with the capacity and the command its slot appends' do
          expect(value(queued)).to eq(Queued)

          enqueue = dispatched_entering(queued).grep(WorkQueue::Enqueue)
          expect(enqueue.map { it.payload.to_h }).to eq(
            [{ queue_name: 'scans', capacity: 3, item_id: job,
               start: { type: StartScan.type, payload: { document_id: } } }]
          )
        end

        it 'moves on to scanning when its slot starts it, keeping the slot' do
          expect(value(uploaded)).to eq(scanning(Scanning::Preparing))
          expect(dispatched_entering(uploaded).grep(WorkQueue::Release)).to be_empty
        end

        it 'gives its place up when discarded before its turn' do
          discarded = history(cmd(DiscardDocument), given: queued)

          release = dispatched_entering(discarded).grep(WorkQueue::Release)
          expect(release.map { it.payload.to_h }).to eq([{ queue_name: 'scans', item_id: job }])
        end

        it 'frees its slot leaving scanning, however it leaves' do
          [cmd(DiscardDocument), cmd(TimeOutScan), cmd(Scanning::FailPreparation, reason: 'Corrupt file')].each do |leave|
            left = history(leave, given: uploaded)
            expect(dispatched_entering(left).grep(WorkQueue::Release).map { it.payload.item_id }).to eq([job]), leave.class.name
          end
          expect(dispatched_entering(scanned).grep(WorkQueue::Release).size).to eq(1)
        end

        it 'queues again on a rescan' do
          rescanned = history(cmd(Rescan, reference_date: today), given: scanned)

          expect(value(rescanned)).to eq(Queued)
          expect(dispatched_entering(rescanned).grep(WorkQueue::Enqueue).size).to eq(1)
        end

        it 'ignores a StartScan that arrives once it has left the queue' do
          discarded = history(cmd(DiscardDocument), given: queued)
          read = Sourced::ReadResult.new(messages: discarded,
                                         guard: Sourced::ConsistencyGuard.new(selector: Sourced::Selector::NONE, last_position: 0))
          pairs = Document.handle_batch({ document_id: }, [cmd(StartScan)], history: read, replaying: false)
          expect(pairs.flat_map { |actions, _| Array(actions) }).to all(be_a(Sourced::Actions::Ack))
        end
      end

      describe 'scanning' do
        it 'starts preparing the file once it has a scanning slot, with the reference date for the scan' do
          doc = document(uploaded).context

          expect(value(uploaded)).to eq(scanning(Scanning::Preparing))
          expect(doc.reference_date).to eq(today)
          expect(doc.filing_country).to eq('NL')
        end

        it 'goes from a plausible extraction with a clear date straight to cleaning' do
          expect(value(extracted)).to eq(scanning(Scanning::Cleaning))
        end

        it 'fails the scan when the extraction call fails' do
          failed = history(cmd(Scanning::FailExtraction, reason: 'API timeout'), given: extracting)

          expect(value(failed)).to eq(ScanFailed)
          expect(document(failed).context.failure).to eq(step: 'extracting', reason: 'API timeout')
          expect(drafts(failed)).to be_empty
        end

        describe 'an implausible extraction' do
          let(:doubtful) { extracted(total_amount: nil, confidence: 'low') }

          it 'asks whether the document is a receipt, telling what went wrong' do
            expect(value(doubtful)).to eq(scanning(Scanning::Verifying))
            expect(document(doubtful).context.extraction_errors).to eq(['Missing total amount', 'Low confidence extraction'])
          end

          it 'takes an extraction missing keys, as nil, and doubts it' do
            sparse = history(cmd(Scanning::CompleteExtraction, total_amount: 10, confidence: 'high'), given: extracting)

            expect(value(sparse)).to eq(scanning(Scanning::Verifying))
            expect(document(sparse).context.extraction_errors).to eq(['Missing currency', 'Missing date', 'Missing description'])
          end

          it 'flags a date that is not ISO 8601' do
            odd = extracted(date: '9 Aug 2026')

            expect(value(odd)).to eq(scanning(Scanning::Verifying))
            expect(document(odd).context.extraction_errors).to eq(['Invalid date format (9 Aug 2026)'])
          end

          it 'flags amounts with more than two decimals' do
            expect(value(extracted(total_amount: 24.205))).to eq(scanning(Scanning::Verifying))
          end

          it 'goes on to the date check when it is a receipt' do
            verified = history(cmd(Scanning::CompleteVerification, is_invoice_or_receipt: true, explanation: 'A crumpled receipt'),
                               given: doubtful)
            expect(value(verified)).to eq(scanning(Scanning::Cleaning))
          end

          it 'rejects it with the explanation when it is not, drafting no expense' do
            rejected = history(cmd(Scanning::CompleteVerification, is_invoice_or_receipt: false, explanation: 'A photo of a cat'),
                               given: doubtful)

            expect(value(rejected)).to eq(Rejected)
            expect(document(rejected).context.verification).to eq(is_invoice_or_receipt: false, explanation: 'A photo of a cat')
            expect(drafts(rejected)).to be_empty
          end
        end

        describe 'the date' do
          let(:old_numeric) { extracted(date_as_printed: '11/03/2026', date: '2026-03-11') }

          def recheck(date, given: old_numeric)
            history(cmd(Scanning::CompleteDateRecheck, date_as_printed: '11/08/2026', date:, reasoning: 'Closest to today',
                                                       candidates: [{ date:, reading: 'DD/MM/YYYY', in_the_future: false }]),
                    given:)
          end

          it 'rechecks an all-numeric date more than 60 days old' do
            expect(value(old_numeric)).to eq(scanning(Scanning::RecheckingDate))
          end

          it 'rechecks an all-numeric date after the reference date' do
            expect(value(extracted(date_as_printed: '11/09/2026', date: '2026-09-11'))).to eq(scanning(Scanning::RecheckingDate))
          end

          it 'trusts an old date with the month spelled out' do
            expect(value(extracted(date_as_printed: '11 Mar 2026', date: '2026-03-11'))).to eq(scanning(Scanning::Cleaning))
          end

          it 'takes a better reading, and drops the datetime that carried the old one' do
            doc = document(recheck('2026-08-03')).context

            expect(doc.extraction).to include(date: '2026-08-03', datetime: nil)
            expect(doc.date_recheck).to include(corrected_date: '2026-08-03', previous_date: '2026-03-11')
          end

          it 'keeps the first reading over one that is not ISO 8601' do
            doc = document(recheck('3 Aug 2026')).context

            expect(doc.extraction[:date]).to eq('2026-03-11')
            expect(doc.date_recheck).to include(corrected_date: nil)
          end

          it 'keeps the first reading over one in the future' do
            doc = document(recheck('2026-11-03')).context

            expect(doc.extraction[:date]).to eq('2026-03-11')
            expect(doc.date_recheck).to include(corrected_date: nil)
          end

          it 'keeps the first reading when the recheck fails' do
            failed = history(cmd(Scanning::FailDateRecheck, reason: 'API error'), given: old_numeric)

            expect(value(failed)).to eq(scanning(Scanning::Cleaning))
            expect(document(failed).context.extraction[:date]).to eq('2026-03-11')
          end
        end

        it 'gives up on a scan that takes too long' do
          *before, entered = uploaded
          timer = nil
          before.reduce(with_reactor(Document, document_id:)) { |gwt, msg| gwt.given(msg) }
                .when(entered).then { |result| timer = result.messages.find { TimeOutScan === it } }

          expect(timer.created_at).to be_within(1).of(entered.created_at + 600)

          timed_out = history(timer, given: uploaded)
          expect(value(timed_out)).to eq(ScanFailed)
          expect(document(timed_out).handles_command?(cmd(Scanning::CompletePreparation, processed_file_ref: 'x'))).to be(false)
        end

        it 'starts over on a rescan, forgetting the last scan' do
          rescanned = history(cmd(Rescan, reference_date: Date.new(2026, 9, 1)), cmd(StartScan), given: scanned)
          doc = document(rescanned).context

          expect(value(rescanned)).to eq(scanning(Scanning::Preparing))
          expect(doc.extraction).to be_nil
          expect(doc.reference_date).to eq(Date.new(2026, 9, 1))
          expect(doc.scans).to eq(2)
        end
      end

      describe 'drafting its expense' do
        def draft(history)
          found = drafts(history)
          expect(found.size).to eq(1)
          found.first.payload.to_h
        end

        it 'drafts its expense once read, under its own id, in cents, with the cleaned text' do
          expect(value(scanned)).to eq(Scanned)
          expect(draft(scanned)).to eq(
            expense_id: document_id, document_id:, filing_country: 'NL', vendor: 'Café Central',
            description: 'Café Central - Lunch', net_price_cents: 2000, tax_amount_cents: 420, tax_description: 'BTW 21%',
            currency: 'EUR', incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL', reverse_charge: false,
            payment_reference: 'R-1234'
          )
        end

        it 'books a total-only receipt as net with zero tax' do
          expect(draft(scanned(net_amount: nil, tax_amount: nil, total_amount: 12.5)))
            .to include(net_price_cents: 1250, tax_amount_cents: 0)
        end

        # A draft's currency is three letters: whatever else the model read
        # must still make a valid DraftExpenseFromDocument, or the draft never lands.
        it 'drafts a valid expense whatever currency the model read' do
          { 'eur' => 'EUR', ' gbp ' => 'GBP', '€' => nil, 'Euro' => nil }.each do |read, drafted|
            found = draft(scanned(currency: read))
            expect(found[:currency]).to eq(drafted), read.inspect
            expect(Expense::DraftExpenseFromDocument.new(payload: found)).to be_valid, read.inspect
          end
        end

        it 'keeps the original text when the cleanup fails' do
          done = history(cmd(Scanning::FailCleanup, reason: 'timeout'), given: extracted(description: 'CafÃ© - Lunch'))

          expect(value(done)).to eq(Scanned)
          expect(draft(done)[:description]).to eq('CafÃ© - Lunch')
        end

        it 'drafts it again, as read the second time, after a rescan' do
          again = history(cmd(Rescan, reference_date: today), cmd(StartScan),
                          cmd(Scanning::CompletePreparation, processed_file_ref: 'tmp/lunch-small.jpg'),
                          cmd(Scanning::CompleteExtraction, **extraction(total_amount: 30.0, net_amount: 25.0, tax_amount: 5.0)),
                          cmd(Scanning::CompleteCleanup, description: 'Café Central - Dinner', tax_description: 'BTW 21%'),
                          given: scanned)

          expect(value(again)).to eq(Scanned)
          expect(draft(again)).to include(description: 'Café Central - Dinner', net_price_cents: 2500, tax_amount_cents: 500)
        end

        it 'lets a person draft it by hand, empty, when the scan failed' do
          failed = history(cmd(Scanning::FailPreparation, reason: 'Corrupt file'), given: uploaded)
          by_hand = history(cmd(EnterManually), given: failed)

          expect(value(by_hand)).to eq(EnteredByHand)
          expect(draft(by_hand).compact).to eq(expense_id: document_id, document_id:, filing_country: 'NL')
        end

        it 'lets a person draft it by hand when it was rejected' do
          rejected = history(cmd(Scanning::CompleteVerification, is_invoice_or_receipt: false, explanation: 'A cat'),
                             given: extracted(total_amount: nil))
          by_hand = history(cmd(EnterManually), given: rejected)

          expect(value(by_hand)).to eq(EnteredByHand)
          expect(drafts(by_hand).size).to eq(1)
        end

        it 'can be scanned again, or discarded, once drafted by hand' do
          by_hand = history(cmd(Scanning::FailPreparation, reason: 'Corrupt file'), cmd(EnterManually), given: uploaded)

          expect(value(history(cmd(Rescan, reference_date: today), given: by_hand))).to eq(Queued)
          expect(value(history(cmd(DiscardDocument), given: by_hand))).to eq(Discarded)
        end

        it 'takes no EnterManually once read' do
          expect(document(scanned).handles_command?(cmd(EnterManually))).to be(false)
        end
      end

      describe 'discarding' do
        it 'can be discarded once read, and then takes nothing more' do
          discarded = history(cmd(DiscardDocument), given: scanned)

          expect(value(discarded)).to eq(Discarded)
          expect(document(discarded).handles_command?(cmd(Rescan, reference_date: today))).to be(false)
        end
      end
    end
  end
end
