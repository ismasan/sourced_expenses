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
      def filed(state) = { Filed::State => state }

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

      let(:uploaded) do
        history(cmd(UploadDocument, filename: 'lunch.jpg', content_type: 'image/jpeg', file_ref: 'uploads/lunch.jpg',
                                    filing_country: 'NL', reference_date: today))
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

      describe 'scanning' do
        it 'starts preparing the file on upload, with the reference date for the scan' do
          doc = expense(uploaded).context

          expect(value(uploaded)).to eq(scanning(Scanning::Preparing))
          expect(doc.reference_date).to eq(today)
          expect(doc.filing_country).to eq('NL')
        end

        it 'goes from a plausible extraction with a clear date straight to cleaning' do
          expect(value(extracted)).to eq(scanning(Scanning::Cleaning))
        end

        it 'prefills the form from the scan, in cents, with the cleaned text' do
          expect(value(scanned)).to eq(Reviewing)
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

          expect(value(done)).to eq(Reviewing)
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
          rescanned = history(cmd(Rescan, reference_date: Date.new(2026, 9, 1)), given: scanned)
          doc = expense(rescanned).context

          expect(value(rescanned)).to eq(scanning(Scanning::Preparing))
          expect(doc.extraction).to be_nil
          expect(doc.reference_date).to eq(Date.new(2026, 9, 1))
          expect(doc.scans).to eq(2)
        end

        it 'lets a person fill in the form when the scan failed' do
          failed = history(cmd(Scanning::FailPreparation, reason: 'Corrupt file'), given: uploaded)
          expect(value(history(cmd(EnterManually), given: failed))).to eq(Reviewing)
        end
      end

      describe 'filing' do
        it 'infers domestic VAT from a supplier in the filing country' do
          done = file(scanned)

          expect(value(done)).to eq(filed(Filed::VatInferred))
          expect(expense(done).context.vat_treatment).to eq('domestic')
        end

        it 'infers again when corrected in place, staying filed' do
          corrected = file(file(scanned), supplier_country_code: 'DE')

          expect(value(corrected)).to eq(filed(Filed::VatNeedsReview))
          expect(expense(corrected).context.vat_treatment).to eq('foreign_vat')
          expect(expense(corrected).handles_command?(cmd(DiscardDocument))).to be(false)
        end

        it 'infers reverse charge first' do
          done = file(scanned, reverse_charge: true, tax_amount_cents: 0, supplier_country_code: 'IE')
          expect(expense(done).context.vat_treatment).to eq('reverse_charge')
        end

        it 'infers no VAT when none was booked' do
          expect(expense(file(scanned, tax_amount_cents: 0, supplier_country_code: 'US')).context.vat_treatment).to eq('no_vat')
        end

        it 'flags foreign VAT for review' do
          done = file(scanned, supplier_country_code: 'DE')

          expect(value(done)).to eq(filed(Filed::VatNeedsReview))
          expect(expense(done).context.vat_treatment).to eq('foreign_vat')
        end

        it 'treats VAT from an unknown supplier country as foreign' do
          expect(value(file(scanned, supplier_country_code: nil))).to eq(filed(Filed::VatNeedsReview))
        end

        it "keeps a person's choice for good, through edits" do
          confirmed = history(cmd(Filed::ConfirmVatTreatment, treatment: 'import'), given: file(scanned, supplier_country_code: 'DE'))
          expect(value(confirmed)).to eq(filed(Filed::VatConfirmed))

          expect(expense(confirmed).context.draft).to include(supplier_country_code: 'DE')

          refiled = file(confirmed, supplier_country_code: 'FR')
          expect(value(refiled)).to eq(filed(Filed::VatConfirmed))
          expect(expense(refiled).context.vat_treatment).to eq('import')
        end
      end
    end
  end
end
