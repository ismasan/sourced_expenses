# frozen_string_literal: true

require 'sourced/testing/rspec'

# Inside Expense, so its commands, states and parts read by their own names.
module Expenses
  class Expense
    RSpec.describe Expense do
      include Sourced::Testing::RSpec

      let(:expense_id) { '3a1b2c4d5e6f4a7b8c9d0e1f2a3b4c5d' }
      let(:today) { Date.new(2026, 8, 11) }

      def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })
      def history(*commands, given: []) = decided(Expense, { expense_id: }, *commands, given:)
      def expense(history) = Expense.new(expense_id:).tap { it.evolve(history) }
      def value(history) = expense(history).machine.value
      def scanning(state) = { Scanning::State => state }
      def reviewing(category: :initial, vat: :initial) = { Reviewing => { category:, vat: } }

      def choose(given, category = 'general') = history(cmd(ChooseCategory, category:), given:)
      def confirm(given, treatment = 'domestic') = history(cmd(ConfirmVatTreatment, treatment:), given:)
      def reviewed(given) = confirm(choose(given))

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
        before.reduce(with_reactor(Expense, expense_id:)) { |gwt, msg| gwt.given(msg) }
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

      def form(**overrides)
        { description: 'Café Central - Lunch', net_price_cents: 2000, tax_amount_cents: 420, tax_description: 'BTW 21%',
          currency: 'EUR', incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL', reverse_charge: false,
          payment_reference: 'R-1234', **overrides }
      end

      def file(given, **overrides) = history(cmd(SaveExpense, **form(**overrides)), given:)

      it 'is a valid chart' do
        expect(Expenses.machines.map(&:to_h)).to all(include(:states))
      end

      describe 'the scan queue' do
        it 'waits in queued on upload, enqueuing itself on ScanQueue' do
          expect(value(queued)).to eq(Queued)

          enqueue = dispatched_entering(queued).grep(ScanQueue::Enqueue)
          expect(enqueue.map { it.payload.to_h }).to eq([{ queue_name: 'scans', item_id: expense_id }])
        end

        it 'keeps its slot moving on to scanning' do
          expect(value(uploaded)).to eq(scanning(Scanning::Preparing))
          expect(dispatched_entering(uploaded).grep(ScanQueue::Release)).to be_empty
        end

        it 'gives its place up when discarded before its turn' do
          discarded = history(cmd(DiscardDocument), given: queued)

          release = dispatched_entering(discarded).grep(ScanQueue::Release)
          expect(release.map { it.payload.to_h }).to eq([{ queue_name: 'scans', item_id: expense_id }])
        end

        it 'frees its slot leaving scanning, however it leaves' do
          [cmd(DiscardDocument), cmd(TimeOutScan), cmd(Scanning::FailPreparation, reason: 'Corrupt file')].each do |leave|
            left = history(leave, given: uploaded)
            expect(dispatched_entering(left).grep(ScanQueue::Release).size).to eq(1), leave.class.name
          end
          expect(dispatched_entering(scanned).grep(ScanQueue::Release).size).to eq(1)
        end

        it 'queues again on a rescan' do
          rescanned = history(cmd(Rescan, reference_date: today), given: scanned)

          expect(value(rescanned)).to eq(Queued)
          expect(dispatched_entering(rescanned).grep(ScanQueue::Enqueue).size).to eq(1)
        end

        it 'ignores a StartScan that arrives once it has left the queue' do
          discarded = history(cmd(DiscardDocument), given: queued)
          read = Sourced::ReadResult.new(messages: discarded,
                                         guard: Sourced::ConsistencyGuard.new(selector: Sourced::Selector::NONE, last_position: 0))
          pairs = Expense.handle_batch({ expense_id: }, [cmd(StartScan)], history: read, replaying: false)

          expect(pairs.flat_map { |actions, _| Array(actions) }).to all(be_a(Sourced::Actions::Ack))
        end
      end

      describe 'scanning' do
        it 'starts preparing the file once it has a scanning slot, with the reference date for the scan' do
          doc = expense(uploaded).context

          expect(value(uploaded)).to eq(scanning(Scanning::Preparing))
          expect(doc.reference_date).to eq(today)
          expect(doc.filing_country).to eq('NL')
        end

        it 'goes from a plausible extraction with a clear date straight to cleaning' do
          expect(value(extracted)).to eq(scanning(Scanning::Cleaning))
        end

        it 'prefills the form from the scan, in cents, with the cleaned text' do
          expect(value(scanned)).to eq(reviewing)
          expect(expense(scanned).context.draft).to include(
            net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR',
            incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL'
          )
        end

        it 'books a total-only receipt as net with zero tax' do
          doc = expense(scanned(net_amount: nil, tax_amount: nil, total_amount: 12.5)).context
          expect(doc.draft).to include(net_price_cents: 1250, tax_amount_cents: 0)
        end

        it 'keeps the original text when the cleanup fails' do
          done = history(cmd(Scanning::FailCleanup, reason: 'timeout'), given: extracted(description: 'CafÃ© - Lunch'))

          expect(value(done)).to eq(reviewing)
          expect(expense(done).context.draft[:description]).to eq('CafÃ© - Lunch')
        end

        it 'fails the scan when the extraction call fails' do
          failed = history(cmd(Scanning::FailExtraction, reason: 'API timeout'), given: extracting)

          expect(value(failed)).to eq(ScanFailed)
          expect(expense(failed).context.failure).to eq(step: 'extracting', reason: 'API timeout')
        end

        describe 'an implausible extraction' do
          let(:doubtful) { extracted(total_amount: nil, confidence: 'low') }

          it 'asks whether the document is a receipt, telling what went wrong' do
            expect(value(doubtful)).to eq(scanning(Scanning::Verifying))
            expect(expense(doubtful).context.extraction_errors).to eq(['Missing total amount', 'Low confidence extraction'])
          end

          it 'takes an extraction missing keys, as nil, and doubts it' do
            sparse = history(cmd(Scanning::CompleteExtraction, total_amount: 10, confidence: 'high'), given: extracting)

            expect(value(sparse)).to eq(scanning(Scanning::Verifying))
            expect(expense(sparse).context.extraction_errors).to eq(['Missing currency', 'Missing date', 'Missing description'])
          end

          it 'flags a date that is not ISO 8601' do
            odd = extracted(date: '9 Aug 2026')

            expect(value(odd)).to eq(scanning(Scanning::Verifying))
            expect(expense(odd).context.extraction_errors).to eq(['Invalid date format (9 Aug 2026)'])
          end

          it 'flags amounts with more than two decimals' do
            expect(value(extracted(total_amount: 24.205))).to eq(scanning(Scanning::Verifying))
          end

          it 'goes on to the date check when it is a receipt' do
            verified = history(cmd(Scanning::CompleteVerification, is_invoice_or_receipt: true, explanation: 'A crumpled receipt'),
                               given: doubtful)
            expect(value(verified)).to eq(scanning(Scanning::Cleaning))
          end

          it 'rejects it with the explanation when it is not' do
            rejected = history(cmd(Scanning::CompleteVerification, is_invoice_or_receipt: false, explanation: 'A photo of a cat'),
                               given: doubtful)

            expect(value(rejected)).to eq(Rejected)
            expect(expense(rejected).context.verification).to eq(is_invoice_or_receipt: false, explanation: 'A photo of a cat')
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
            doc = expense(recheck('2026-08-03')).context

            expect(doc.extraction).to include(date: '2026-08-03', datetime: nil)
            expect(doc.date_recheck).to include(corrected_date: '2026-08-03', previous_date: '2026-03-11')
          end

          it 'keeps the first reading over one that is not ISO 8601' do
            doc = expense(recheck('3 Aug 2026')).context

            expect(doc.extraction[:date]).to eq('2026-03-11')
            expect(doc.date_recheck).to include(corrected_date: nil)
          end

          it 'keeps the first reading over one in the future' do
            doc = expense(recheck('2026-11-03')).context

            expect(doc.extraction[:date]).to eq('2026-03-11')
            expect(doc.date_recheck).to include(corrected_date: nil)
          end

          it 'keeps the first reading when the recheck fails' do
            failed = history(cmd(Scanning::FailDateRecheck, reason: 'API error'), given: old_numeric)

            expect(value(failed)).to eq(scanning(Scanning::Cleaning))
            expect(expense(failed).context.extraction[:date]).to eq('2026-03-11')
          end
        end

        it 'gives up on a scan that takes too long' do
          *before, entered = uploaded
          timer = nil
          before.reduce(with_reactor(Expense, expense_id:)) { |gwt, msg| gwt.given(msg) }
                .when(entered).then { |result| timer = result.messages.find { TimeOutScan === it } }

          expect(timer.created_at).to be_within(1).of(entered.created_at + 600)

          timed_out = history(timer, given: uploaded)
          expect(value(timed_out)).to eq(ScanFailed)
          expect(expense(timed_out).handles_command?(cmd(Scanning::CompletePreparation, processed_file_ref: 'x'))).to be(false)
        end

        it 'starts over on a rescan, forgetting the last scan' do
          rescanned = history(cmd(Rescan, reference_date: Date.new(2026, 9, 1)), cmd(StartScan), given: scanned)
          doc = expense(rescanned).context

          expect(value(rescanned)).to eq(scanning(Scanning::Preparing))
          expect(doc.extraction).to be_nil
          expect(doc.reference_date).to eq(Date.new(2026, 9, 1))
          expect(doc.scans).to eq(2)
        end

        it 'lets a person fill in the form when the scan failed' do
          failed = history(cmd(Scanning::FailPreparation, reason: 'Corrupt file'), given: uploaded)
          expect(value(history(cmd(EnterManually), given: failed))).to eq(reviewing)
        end
      end

      describe 'reviewing' do
        def vat(history) = expense(history).context.suggested_vat_treatment

        it 'suggests domestic VAT from a supplier in the filing country' do
          expect(vat(scanned)).to eq('domestic')
          expect(expense(scanned).context.vat_needs_review?).to be(false)
        end

        it 'suggests reverse charge first' do
          expect(vat(scanned(reverse_charge: true, tax_amount: 0.0, supplier_country_code: 'IE'))).to eq('reverse_charge')
        end

        it 'suggests no VAT when none was booked' do
          expect(vat(scanned(tax_amount: 0.0, supplier_country_code: 'US'))).to eq('no_vat')
        end

        it 'flags foreign VAT, and VAT from an unknown supplier country, for a closer look' do
          [scanned(supplier_country_code: 'DE'), scanned(supplier_country_code: nil)].each do |foreign|
            expect(vat(foreign)).to eq('foreign_vat')
            expect(expense(foreign).context.vat_needs_review?).to be(true)
          end
        end

        it 'suggests nothing for a form filled in by hand' do
          by_hand = history(cmd(Scanning::FailPreparation, reason: 'Corrupt file'), cmd(EnterManually), given: uploaded)

          expect(vat(by_hand)).to be_nil
          expect(expense(by_hand).context.vat_needs_review?).to be(true)
        end

        it 'forgets the last scan’s form on a rescan, so a failed one suggests nothing' do
          by_hand = history(cmd(Rescan, reference_date: today), cmd(StartScan), cmd(Scanning::FailPreparation, reason: 'Corrupt file'),
                            cmd(EnterManually), given: scanned)

          expect(expense(by_hand).context.draft).to eq({})
          expect(vat(by_hand)).to be_nil
        end

        it 'files nothing until the category is chosen and the VAT treatment confirmed, in either order' do
          can_file = ->(history) { expense(history).handles_command?(cmd(SaveExpense, **form)) }
          expect(can_file.(scanned)).to be(false)

          vat_first = confirm(scanned, 'import')
          expect(value(vat_first)).to eq(reviewing(vat: VatConfirmed))
          expect(can_file.(vat_first)).to be(false)
          expect(value(choose(vat_first))).to eq(Reviewed)

          category_first = choose(scanned, 'travel')
          expect(value(category_first)).to eq(reviewing(category: CategoryConfirmed))
          expect(can_file.(category_first)).to be(false)

          done = confirm(category_first)
          expect(value(done)).to eq(Reviewed)
          expect(can_file.(done)).to be(true)
          expect(expense(done).context).to have_attributes(category: 'travel', vat_treatment: 'domestic',
                                                           vat_treatment_confirmed?: true)
        end

        it 'takes a change to a step already done while the other waits' do
          rechosen = choose(choose(scanned, 'travel'), 'general')

          expect(value(rechosen)).to eq(reviewing(category: CategoryConfirmed))
          expect(expense(rechosen).context.category).to eq('general')
          expect(expense(confirm(confirm(scanned), 'import')).context.vat_treatment).to eq('import')
        end

        it 'takes a change of mind once reviewed, and ignores repeats' do
          changed = history(cmd(ConfirmVatTreatment, treatment: 'import'), cmd(ChooseCategory, category: 'travel'),
                            given: reviewed(scanned))

          expect(value(changed)).to eq(Reviewed)
          expect(expense(changed).context).to have_attributes(vat_treatment: 'import', category: 'travel')
          expect(history(cmd(ConfirmVatTreatment, treatment: 'import'), given: changed)).to eq(changed)
        end

        describe 'scanned again' do
          def scan_again(given)
            history(cmd(Rescan, reference_date: today), cmd(StartScan),
                    cmd(Scanning::CompletePreparation, processed_file_ref: 'tmp/lunch-small.jpg'),
                    cmd(Scanning::CompleteExtraction, **extraction),
                    cmd(Scanning::CompleteCleanup, description: 'Café Central - Lunch', tax_description: 'BTW 21%'), given:)
          end

          it 'keeps a step done before the rescan' do
            expect(value(scan_again(confirm(scanned, 'import')))).to eq(reviewing(vat: VatConfirmed))
          end

          it 'comes back reviewed once both were done' do
            expect(value(scan_again(reviewed(scanned)))).to eq(Reviewed)
          end
        end
      end

      describe 'filing' do
        it 'files the reviewed form' do
          done = file(reviewed(scanned))

          expect(value(done)).to eq(Filed)
          expect(expense(done).context.filed).to include(net_price_cents: 2000, supplier_country_code: 'NL')
        end

        it 'keeps the confirmed VAT treatment when corrected in place, staying filed' do
          corrected = file(file(confirm(choose(scanned), 'import')), supplier_country_code: 'DE')

          expect(value(corrected)).to eq(Filed)
          expect(expense(corrected).context).to have_attributes(vat_treatment: 'import', suggested_vat_treatment: 'foreign_vat')
          expect(expense(corrected).handles_command?(cmd(DiscardDocument))).to be(false)
        end

        it 'takes a change of category or VAT treatment once filed' do
          changed = history(cmd(ConfirmVatTreatment, treatment: 'no_vat'), cmd(ChooseCategory, category: 'travel'),
                            given: file(reviewed(scanned)))

          expect(value(changed)).to eq(Filed)
          expect(expense(changed).context).to have_attributes(vat_treatment: 'no_vat', category: 'travel')
        end
      end
    end
  end
end
