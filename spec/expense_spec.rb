# frozen_string_literal: true

require 'sourced/testing/rspec'

# Inside Expense, so its commands and states read by their own names.
module Expenses
  class Expense
    RSpec.describe Expense do
      include Sourced::Testing::RSpec

      let(:expense_id) { '3a1b2c4d5e6f4a7b8c9d0e1f2a3b4c5d' }

      def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })
      def history(*commands, given: []) = decided(Expense, { expense_id: }, *commands, given:)
      def expense(history) = Expense.new(expense_id:).tap { it.evolve(history) }
      def value(history) = expense(history).machine.value
      def reviewing(category: :initial, vat: :initial) = { Reviewing => { category:, vat: } }

      def choose(given, category = 'general') = history(cmd(ChooseCategory, category:), given:)
      def confirm(given, treatment = 'domestic') = history(cmd(ConfirmVatTreatment, treatment:), given:)
      def reviewed(given) = confirm(choose(given))

      # A draft as a scan of a Dutch lunch receipt makes it.
      def prefill(**overrides)
        { document_id: expense_id, filing_country: 'NL', vendor: 'Café Central', description: 'Café Central - Lunch',
          net_price_cents: 2000, tax_amount_cents: 420, tax_description: 'BTW 21%', currency: 'EUR',
          incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL', reverse_charge: false,
          payment_reference: 'R-1234', **overrides }
      end

      def drafted(given: [], **overrides) = history(cmd(DraftExpenseFromDocument, **prefill(**overrides)), given:)

      def form(**overrides)
        { description: 'Café Central - Lunch', net_price_cents: 2000, tax_amount_cents: 420, tax_description: 'BTW 21%',
          currency: 'EUR', incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL', reverse_charge: false,
          payment_reference: 'R-1234', **overrides }
      end

      def file(given, **overrides) = history(cmd(SaveExpense, **form(**overrides)), given:)

      describe 'drafting' do
        it 'starts in review with the draft as the form' do
          doc = expense(drafted).context

          expect(value(drafted)).to eq(reviewing)
          expect(doc.draft).to eq(form)
          expect(doc).to have_attributes(document_id: expense_id, document?: true, vendor: 'Café Central', filing_country: 'NL')
        end

        it 'changes nothing drafted the same again' do
          first = drafted
          expect(drafted(given: first)).to eq(first)
        end

        it 'records the draft and the document it was read from, each as an event of its own' do
          expect(drafted.map(&:class)).to include(ExpenseDrafted, DocumentAttached)
          expect(expense(drafted).context).not_to be_entered
        end

        it 'takes a new draft only from its own document' do
          first = drafted
          expect(drafted(given: first, document_id: 'f' * 32, description: 'Another receipt')).to eq(first)
        end

        it 'is redrafted while in review, keeping the steps done' do
          given = confirm(drafted, 'import')
          redrafted = drafted(given:, description: 'Café Central - Dinner', net_price_cents: 2500)

          expect(redrafted.drop(given.size).map(&:class)).to eq([ExpenseRedrafted])
          expect(value(redrafted)).to eq(reviewing(vat: VatConfirmed))
          expect(expense(redrafted).context.draft).to include(description: 'Café Central - Dinner', net_price_cents: 2500)
          expect(expense(redrafted).context.vat_treatment).to eq('import')
        end

        it 'stays reviewed with a new draft once both steps are done' do
          redrafted = drafted(given: reviewed(drafted), description: 'Café Central - Dinner')

          expect(value(redrafted)).to eq(Reviewed)
          expect(expense(redrafted).context.draft[:description]).to eq('Café Central - Dinner')
        end

        it 'ignores a new draft once filed: what was filed stands' do
          filed = file(reviewed(drafted))

          expect(expense(filed).handles_command?(cmd(DraftExpenseFromDocument, **prefill(description: 'Something else')))).to be(false)
          expect(expense(filed).context.draft[:description]).to eq('Café Central - Lunch')
        end

        it 'takes an empty draft, with nothing to suggest a VAT treatment from' do
          empty = history(cmd(DraftExpenseFromDocument, document_id: expense_id, filing_country: 'NL'))
          doc = expense(empty).context

          expect(value(empty)).to eq(reviewing)
          expect(doc.draft.compact).to eq({})
          expect(doc.suggested_vat_treatment).to be_nil
          expect(doc.vat_needs_review?).to be(true)
        end

        describe 'by hand, with no document' do
          let(:expense_id) { 'b6f2c1e0-3a4d-4b5c-9e8f-7a6b5c4d3e2f' }

          it 'is reviewed and filed as any other' do
            by_hand = history(cmd(EnterExpense, filing_country: 'NL', **form))

            expect(by_hand.map(&:class)).to include(ExpenseEntered)
            expect(by_hand.map(&:class)).not_to include(ExpenseDrafted, DocumentAttached)
            expect(value(by_hand)).to eq(reviewing)
            expect(expense(by_hand).context).to have_attributes(document_id: nil, document?: false, entered?: true, draft: form)
            expect(value(file(reviewed(by_hand)))).to eq(Filed)
          end

          it 'changes nothing entered the same again, nor takes a document’s draft' do
            by_hand = history(cmd(EnterExpense, filing_country: 'NL', **form))

            expect(expense(by_hand).handles_command?(cmd(EnterExpense, filing_country: 'NL', **form))).to be(false)
            expect(history(cmd(DraftExpenseFromDocument, **prefill(document_id: 'f' * 32)), given: by_hand)).to eq(by_hand)
          end

          it 'refuses an id that is not safe in a URL' do
            expect(EnterExpense.new(payload: { expense_id: 'a/b.c', filing_country: 'NL', **form })).not_to be_valid
          end
        end
      end

      describe 'reviewing' do
        def vat(history) = expense(history).context.suggested_vat_treatment

        it 'suggests domestic VAT from a supplier in the filing country' do
          expect(vat(drafted)).to eq('domestic')
          expect(expense(drafted).context.vat_needs_review?).to be(false)
        end

        it 'suggests reverse charge first' do
          expect(vat(drafted(reverse_charge: true, tax_amount_cents: 0, supplier_country_code: 'IE'))).to eq('reverse_charge')
        end

        it 'suggests no VAT when none was booked' do
          expect(vat(drafted(tax_amount_cents: 0, supplier_country_code: 'US'))).to eq('no_vat')
        end

        it 'flags foreign VAT, and VAT from an unknown supplier country, for a closer look' do
          [drafted(supplier_country_code: 'DE'), drafted(supplier_country_code: nil)].each do |foreign|
            expect(vat(foreign)).to eq('foreign_vat')
            expect(expense(foreign).context.vat_needs_review?).to be(true)
          end
        end

        it 'files nothing until the category is chosen and the VAT treatment confirmed, in either order' do
          can_file = ->(history) { expense(history).handles_command?(cmd(SaveExpense, **form)) }
          expect(can_file.(drafted)).to be(false)

          vat_first = confirm(drafted, 'import')
          expect(value(vat_first)).to eq(reviewing(vat: VatConfirmed))
          expect(can_file.(vat_first)).to be(false)
          expect(value(choose(vat_first))).to eq(Reviewed)

          category_first = choose(drafted, 'travel')
          expect(value(category_first)).to eq(reviewing(category: CategoryConfirmed))
          expect(can_file.(category_first)).to be(false)

          done = confirm(category_first)
          expect(value(done)).to eq(Reviewed)
          expect(can_file.(done)).to be(true)
          expect(expense(done).context).to have_attributes(category: 'travel', vat_treatment: 'domestic',
                                                           vat_treatment_confirmed?: true)
        end

        it 'takes a change to a step already done while the other waits' do
          rechosen = choose(choose(drafted, 'travel'), 'general')

          expect(value(rechosen)).to eq(reviewing(category: CategoryConfirmed))
          expect(expense(rechosen).context.category).to eq('general')
          expect(expense(confirm(confirm(drafted), 'import')).context.vat_treatment).to eq('import')
        end

        it 'takes a change of mind once reviewed, and ignores repeats' do
          changed = history(cmd(ConfirmVatTreatment, treatment: 'import'), cmd(ChooseCategory, category: 'travel'),
                            given: reviewed(drafted))

          expect(value(changed)).to eq(Reviewed)
          expect(expense(changed).context).to have_attributes(vat_treatment: 'import', category: 'travel')
          expect(history(cmd(ConfirmVatTreatment, treatment: 'import'), given: changed)).to eq(changed)
        end

        it 'takes the model’s category until a person chooses one, and ignores repeats' do
          suggest = cmd(SuggestCategory, category: 'travel', probability: 0.8, description: 'Café Central - Lunch')
          suggested = history(suggest, given: drafted)

          expect(expense(suggested).context).to have_attributes(category: 'travel', category_chosen?: false)
          expect(history(suggest, given: suggested)).to eq(suggested)

          chosen = choose(suggested, 'business_entertaining')
          expect(history(suggest, given: chosen)).to eq(chosen)
          expect(expense(chosen).context.category).to eq('business_entertaining')
        end

        it 'records a failed categorization, unless a person has chosen' do
          failure = cmd(FailCategorization, description: 'Café Central - Lunch', reason: 'Rate limited')

          expect(expense(history(failure, given: drafted)).context.categorization_failure).to include(reason: 'Rate limited')
          chosen = choose(drafted)
          expect(history(failure, given: chosen)).to eq(chosen)
        end

        it 'can be discarded, and then takes nothing more' do
          [drafted, reviewed(drafted)].each do |given|
            discarded = history(cmd(DiscardExpense), given:)
            expect(value(discarded)).to eq(Discarded)
            expect(expense(discarded).handles_command?(cmd(DraftExpenseFromDocument, **prefill))).to be(false)
          end
        end
      end

      describe 'filing' do
        it 'files the reviewed form' do
          done = file(reviewed(drafted))

          expect(value(done)).to eq(Filed)
          expect(expense(done).context.filed).to include(net_price_cents: 2000, supplier_country_code: 'NL')
        end

        it 'keeps the confirmed VAT treatment when corrected in place, staying filed' do
          corrected = file(file(confirm(choose(drafted), 'import')), supplier_country_code: 'DE')

          expect(value(corrected)).to eq(Filed)
          expect(expense(corrected).context).to have_attributes(vat_treatment: 'import', suggested_vat_treatment: 'foreign_vat')
          expect(expense(corrected).handles_command?(cmd(DiscardExpense))).to be(false)
        end

        it 'takes a change of category or VAT treatment once filed' do
          changed = history(cmd(ConfirmVatTreatment, treatment: 'no_vat'), cmd(ChooseCategory, category: 'travel'),
                            given: file(reviewed(drafted)))

          expect(value(changed)).to eq(Filed)
          expect(expense(changed).context).to have_attributes(vat_treatment: 'no_vat', category: 'travel')
        end

        it 'is voided with a reason' do
          voided = history(cmd(VoidExpense, reason: 'Duplicate'), given: file(reviewed(drafted)))

          expect(value(voided)).to eq(Voided)
          expect(expense(voided).handles_command?(cmd(SaveExpense, **form))).to be(false)
        end
      end

      describe 'the conversion' do
        let(:filed) { file(reviewed(drafted)) }

        def conversion(**overrides)
          { currency: 'EUR', amount_cents: 2420, incurred_on: Date.new(2026, 8, 9), reporting_currency: 'GBP',
            reporting_cents: 2100, rate: 0.8678, rate_date: Date.new(2026, 8, 9), **overrides }
        end

        it 'records the filed total’s conversion once' do
          recorded = history(cmd(RecordConversion, **conversion), given: filed)

          expect(expense(recorded).context.converted).to eq(conversion)
          expect(history(cmd(RecordConversion, **conversion), given: recorded)).to eq(recorded)
        end

        it 'drops a conversion of an amount since corrected' do
          corrected = file(filed, net_price_cents: 3000)

          expect(history(cmd(RecordConversion, **conversion), given: corrected)).to eq(corrected)
        end

        it 'forgets a conversion once the total it was for is corrected' do
          recorded = history(cmd(RecordConversion, **conversion), given: filed)

          expect(expense(file(recorded, net_price_cents: 3000)).context.converted).to be_nil
          expect(expense(file(recorded, description: 'Lunch')).context.converted).to eq(conversion)
        end

        it 'records a failed conversion, cleared by a recorded one' do
          failure = { currency: 'EUR', amount_cents: 2420, incurred_on: Date.new(2026, 8, 9), reporting_currency: 'GBP',
                      reason: 'No rate' }
          failed = history(cmd(FailConversion, **failure), given: filed)

          expect(expense(failed).context.conversion_failure).to eq(failure)
          expect(expense(history(cmd(RecordConversion, **conversion), given: failed)).context.conversion_failure).to be_nil
        end

        it 'takes none before the expense is filed' do
          expect(expense(reviewed(drafted)).handles_command?(cmd(RecordConversion, **conversion))).to be(false)
        end
      end

      describe 'imported' do
        # Events stored before ImportExpense had an external_url still load.
        it 'reads an import stored without a link' do
          payload = { expense_id:, source: 'freeagent', external_id: '1', filing_country: 'GB', description: 'Lunch',
                      net_price_cents: 2000, tax_amount_cents: 400, tax_description: nil, currency: 'GBP',
                      incurred_on: Date.new(2026, 11, 18), supplier_country_code: nil, reverse_charge: false,
                      payment_reference: nil, category: nil, source_category: nil, vat_treatment: 'domestic' }
          [ExpenseImported, ImportedExpenseChanged].each do |klass|
            event = klass.new(payload:)
            expect(event).to be_valid, klass.name
            expect(event.payload.external_url).to be_nil
          end
        end

        let(:expense_id) { 'freeagent-123' }

        # A FreeAgent expense, as Integrations::FreeAgent::ExpenseMapping makes it: a UK
        # lunch, with no supplier country, booked as domestic VAT there.
        def import(**overrides)
          { source: 'freeagent', external_id: '123', filing_country: 'GB', description: 'Pret - Lunch',
            net_price_cents: 2000, tax_amount_cents: 400, tax_description: 'VAT 20%', currency: 'GBP',
            incurred_on: Date.new(2026, 11, 18), supplier_country_code: nil, reverse_charge: false,
            payment_reference: nil, category: 'accommodation_and_meals', source_category: 'Accommodation and Meals',
            vat_treatment: 'domestic', **overrides }
        end

        def imported(given: [], **overrides) = history(cmd(ImportExpense, **import(**overrides)), given:)

        def import_form(**overrides)
          import(**overrides).slice(*DRAFT)
        end

        it 'is filed as its source has it, its category and VAT treatment confirmed, nothing attached' do
          doc = expense(imported).context

          data = [ExpenseImported, CategoryChosen, VatTreatmentConfirmed, ExpenseFiled]
          expect(imported.map(&:class).select { data.include?(it) }).to eq(data)

          expect(value(imported)).to eq(Filed)
          expect(imported.map(&:class)).to include(ExpenseImported, ExpenseFiled)
          expect(imported.map(&:class)).not_to include(ExpenseDrafted, ExpenseEntered, DocumentAttached)
          expect(doc.filed).to eq(import_form)
          expect(doc).to have_attributes(imported?: true, source: 'freeagent', external_id: '123', document?: false,
                                         source_category: 'Accommodation and Meals', filing_country: 'GB',
                                         category: 'accommodation_and_meals', category_chosen?: true,
                                         vat_treatment: 'domestic', vat_treatment_confirmed?: true)
        end

        it 'starts in review, with its source’s category as a suggestion, if it hasn’t all it takes to file' do
          [{ vat_treatment: nil }, { category: nil, source_category: nil }, { description: nil }].each do |missing|
            incomplete = imported(**missing)
            doc = expense(incomplete).context

            expect(value(incomplete)).to eq(reviewing), missing.inspect
            expect(incomplete.map(&:class)).not_to include(ExpenseFiled)
            expect(doc.category_chosen?).to be(false)
          end
          doc = expense(imported(vat_treatment: nil)).context
          expect(doc.category_suggestion).to eq(category: 'accommodation_and_meals', source: 'freeagent')
          # No supplier country, and no treatment from its source: the rule's.
          expect(doc.suggested_vat_treatment).to eq('foreign_vat')
        end

        it 'suggests its source’s VAT treatment over the rule’s, in review' do
          doc = expense(imported(category: nil, source_category: nil)).context

          expect(ExpenseState.suggested_vat_treatment(doc.draft, filing_country: 'GB')).to eq('foreign_vat')
          expect(doc.suggested_vat_treatment).to eq('domestic')
          expect(doc.vat_treatment_confirmed?).to be(false)
        end

        it 'confirms again only what changed there' do
          changed = imported(given: imported, net_price_cents: 2500)

          expect(changed.drop(imported.size).map(&:class)).to eq([ImportedExpenseChanged, ExpenseFiled])
        end

        it 'changes nothing imported the same again' do
          first = imported
          expect(imported(given: first)).to eq(first)
        end

        it 'is filed again with a change at its source, its source winning over a correction here' do
          corrected = file(imported, **import_form(description: 'Pret - Corrected here'))
          changed = imported(given: corrected, net_price_cents: 9900, category: 'general', vat_treatment: 'no_vat')
          doc = expense(changed).context

          expect(changed.drop(corrected.size).map(&:class))
            .to eq([ImportedExpenseChanged, CategoryChosen, VatTreatmentConfirmed, ExpenseFiled])
          expect(value(changed)).to eq(Filed)
          expect(doc.filed).to eq(import_form(net_price_cents: 9900))
          expect(doc).to have_attributes(category: 'general', category_chosen?: true, vat_treatment: 'no_vat')
          expect(imported(given: changed, net_price_cents: 9900, category: 'general', vat_treatment: 'no_vat')).to eq(changed)
        end

        it 'applies a change at its source while in review, keeping a person’s choice while it’s incomplete' do
          given = choose(imported(vat_treatment: nil), 'travel')
          changed = imported(given:, description: 'Pret - Dinner', vat_treatment: nil)
          doc = expense(changed).context

          expect(changed.drop(given.size).map(&:class)).to eq([ImportedExpenseChanged])
          expect(value(changed)).to eq(reviewing(category: CategoryConfirmed))
          expect(doc.draft).to eq(import_form(description: 'Pret - Dinner'))
          expect(doc.category).to eq('travel')
        end

        it 'files it once a change at its source brings all it takes, as its source has it' do
          given = choose(imported(vat_treatment: nil), 'travel')
          changed = imported(given:)
          doc = expense(changed).context

          expect(changed.drop(given.size).map(&:class)).to include(ImportedExpenseChanged, ExpenseFiled)
          expect(value(changed)).to eq(Filed)
          expect(doc).to have_attributes(category: 'accommodation_and_meals', category_chosen?: true,
                                         vat_treatment: 'domestic', vat_treatment_confirmed?: true)
        end

        it 'ignores an import of another source’s expense, or another id' do
          first = imported
          expect(imported(given: first, external_id: '999', description: 'Other')).to eq(first)
          expect(imported(given: first, source: 'xero', description: 'Other')).to eq(first)
        end

        it 'takes none once voided or discarded' do
          voided = history(cmd(VoidExpense, reason: 'Duplicate'), given: imported)
          discarded = history(cmd(DiscardExpense), given: imported(vat_treatment: nil))

          [voided, discarded].each do |closed|
            expect(expense(closed).handles_command?(cmd(ImportExpense, **import(net_price_cents: 1)))).to be(false)
          end
        end
      end
    end
  end
end
