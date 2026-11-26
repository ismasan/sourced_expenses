# frozen_string_literal: true

require 'rack/test'
require_relative 'page_helpers'

# Inside Expenses, so the machines read by their own names.
module Expenses
  RSpec.describe UI::ExpensePage do
    include Rack::Test::Methods
    include PageHelpers

    def app = App

    # An expense drafted from the document: under the document's id.
    let(:expense_id) { document_id }

    def ecmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

    # The document scanned, and its expense after +commands+, the page as it is.
    def at(*commands, document: scan)
      document!(*document)
      expense!(expense_id, drafted(*scan), *commands)
      get "/expenses/#{expense_id}"
      last_response.body
    end

    let(:reviewed) { [ecmd(Expense::ChooseCategory, category: 'travel'), ecmd(Expense::ConfirmVatTreatment, treatment: 'domestic')] }
    let(:save) do
      ecmd(Expense::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR',
                                 incurred_on: Date.new(2026, 8, 7), supplier_country_code: 'NL')
    end

    it 'shows "Drafting…" before the machine has the draft' do
      get "/expenses/#{SecureRandom.uuid}"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Drafting…', 'tabs__tab')
    end

    it 'is not /expenses/new, which is the form for one by hand' do
      get '/expenses/new'

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('web.new_expense')
      expect(last_response.body).not_to include('Drafting…')
    end

    it 'refuses an id that is not one' do
      get '/expenses/not.an%20id'

      expect(last_response.status).to eq(400)
    end

    describe 'drafted from a document' do
      it 'asks for the category and the VAT treatment, with the draft and its document beside it' do
        body = at

        expect(body).to include('<p class="panel-lead callout--attention">', 'Ready to review', 'Café Central — Lunch',
                                '24.20 EUR', 'Suggested VAT treatment: ', '<strong>Domestic</strong>', 'Choose a category')
        expect(body).to include("/files/#{jpeg}/thumbnail", 'file-dialog', %(href="/documents/#{document_id}"), 'Its document', ': Read')
        expect(body).not_to include('File expense', 'value="2000"', 'record-page__body--no-preview')
        expect(body).to match(%r{<button type="submit" class="button button--primary button--suggested" aria-pressed="false">Confirm Domestic</button>})
      end

      it 'offers to scan its document again while in review, as the document’s command' do
        body = at

        expect(body).to include('>Scan again</button>', %(value="#{Document::Rescan.type}"), 'Discard')
        rescan = body[/<form[^>]*>(?:(?!<\/form>).)*Scan again.*?<\/form>/m]
        expect(rescan).to include(%(name="command[payload][document_id]" value="#{document_id}"))
        expect(rescan).not_to include('command[payload][expense_id]')
      end

      it 'says so while its document is read again' do
        body = at(document: [*scan, dcmd(Document::Rescan, reference_date: Date.new(2026, 8, 11))])

        expect(body).to include('Its document is being read again', ': Waiting to be read…')
        expect(body).not_to include('>Scan again</button>')
      end

      it 'shows the suggested category, with every category to choose from' do
        body = at(ecmd(Expense::SuggestCategory, category: 'business_entertaining', probability: 0.82,
                                                 description: 'Café Central — Lunch'))

        expect(body).to include('Suggested category: ', '<strong>Business entertaining</strong>', '82% sure',
                                '>Light, heat and power</option>', 'category__form category__form--suggested')
      end

      it 'flags another country’s VAT for a closer look' do
        doc = [*scan[0..2], dcmd(Document::Scanning::CompleteExtraction, **extraction, supplier_country_code: 'DE'), scan.last]
        document!(*doc)
        expense!(expense_id, drafted(*doc))
        get "/expenses/#{expense_id}"

        expect(last_response.body).to include('<strong>Foreign VAT</strong>', 'Another country’s VAT: check it closely.')
      end

      it 'keeps a step done in view, to change, while the other waits' do
        body = at(ecmd(Expense::ConfirmVatTreatment, treatment: 'import'))

        expect(body).to include('Ready to review', 'VAT treatment: <strong>Import</strong>', 'Choose a category')
        expect(body).to match(%r{<button type="submit" disabled class="button button--selected" aria-pressed="true">Import</button>})
      end

      it 'prefills the form from the draft once reviewed, filing it last, beside the other ways out' do
        body = at(*reviewed)
        file = body.index('<button type="submit" form="review-form" class="button button--primary">File expense</button>')

        expect(body).to include('Ready to file', 'value="Café Central — Lunch"', 'value="2000"', 'value="420"', 'value="2026-08-09"')
        expect(file).to be > body.index('aria-label="VAT treatment"')
        expect(body.index('>Scan again</button>')).to be > file
      end

      it 'files the expense the form posts' do
        at(*reviewed)
        post '/commands', command: { type: Expense::SaveExpense.type, _cid: 'x', payload: {
          expense_id:, description: 'Lunch', net_price_cents: '2000', tax_amount_cents: '420', tax_description: 'BTW 21%',
          currency: 'EUR', incurred_on: '2026-08-09', supplier_country_code: 'NL', reverse_charge: '0', payment_reference: ''
        } }

        saved = store.read_all(limit: 10_000).to_a.reverse.find { it.is_a?(Expense::SaveExpense) }
        expect(saved.payload).to have_attributes(expense_id:, net_price_cents: 2000, payment_reference: nil)
      end

      it 'shows a filed expense with its VAT treatment and total on its way, no longer to scan again' do
        body = at(*reviewed, save)

        expect(body).to include('Filed', '24.20 EUR', 'VAT treatment: <strong>Domestic</strong>', 'Category: <strong>Travel</strong>',
                                'Correct it', 'Void', 'In GBP', 'Converting…')
        expect(body).not_to include('>Scan again</button>', '>Discard</button>')
      end

      it 'shows the converted total once recorded, with the rate' do
        converted = ecmd(Expense::RecordConversion, currency: 'EUR', amount_cents: 2420, incurred_on: Date.new(2026, 8, 7),
                                                    reporting_currency: 'GBP', reporting_cents: 2113, rate: 0.8731,
                                                    rate_date: Date.new(2026, 8, 7))

        expect(at(*reviewed, save, converted)).to include('21.13 GBP', 'at 0.8731 on 7 Aug 2026')
      end

      it 'says so once discarded' do
        expect(at(ecmd(Expense::DiscardExpense))).to include('This expense was discarded')
      end

      it 'says so once voided' do
        expect(at(*reviewed, save, ecmd(Expense::VoidExpense, reason: 'Duplicate'))).to include('This expense was voided')
      end

      it 'follows its own channel and its document’s' do
        body = at

        expect(stream_channels(body)).to eq(["expenses.#{expense_id}", "documents.#{document_id}", 'system.>'])
      end
    end

    describe 'entered by hand' do
      let(:expense_id) { SecureRandom.uuid }
      let(:draft) do
        ecmd(Expense::EnterExpense, filing_country: 'NL', description: 'Train to Leeds', net_price_cents: 4500,
                                    tax_amount_cents: 0, currency: 'GBP', incurred_on: Date.new(2026, 8, 9))
      end

      def at(*commands)
        expense!(expense_id, draft, *commands)
        get "/expenses/#{expense_id}"
        last_response.body
      end

      it 'has nothing beside the review, and no document to scan again' do
        body = at

        expect(body).to include('Train to Leeds', '45.00 GBP', 'Ready to review', 'record-page__body--no-preview',
                                'Suggested VAT treatment: ', '<strong>No VAT</strong>', '>Discard</button>')
        expect(body).not_to include('file-dialog', 'Scan again', 'Its document')
        expect(stream_channels(body)).to eq(["expenses.#{expense_id}", 'system.>'])
      end

      it 'asks for everything when the draft has nothing in it' do
        expense!(expense_id, ecmd(Expense::DraftExpenseFromDocument, document_id: SecureRandom.hex(16), filing_country: 'NL'))
        get "/expenses/#{expense_id}"

        expect(last_response.body).to include('New expense', 'Nothing in the draft yet',
                                              'Nothing in the draft to suggest one from: choose a category.',
                                              'nothing in the draft to suggest one from. Choose one.')
      end
    end

    describe 'imported from FreeAgent' do
      let(:expense_id) { "freeagent-#{SecureRandom.hex(4)}" }

      def import(**overrides)
        ecmd(Expense::ImportExpense, source: 'freeagent', external_id: expense_id.delete_prefix('freeagent-'),
                                     filing_country: 'GB', description: 'Pret - Lunch', net_price_cents: 2000,
                                     tax_amount_cents: 400, currency: 'GBP', incurred_on: Date.new(2026, 11, 18),
                                     category: 'accommodation_and_meals', source_category: 'Accommodation and Meals',
                                     vat_treatment: 'domestic', **overrides)
      end

      def at(*commands)
        expense!(expense_id, import, *commands)
        get "/expenses/#{expense_id}"
        last_response.body
      end

      it 'shows it filed as it is on FreeAgent, a correction here to be made there' do
        body = at

        expect(body).to include('Pret - Lunch', 'Filed, as it is on FreeAgent', 'Accommodation and meals', 'Domestic',
                                'FreeAgent’s next change to it replaces a correction made here', 'record-page__body--no-preview')
        expect(body).not_to include('Read from its document', 'Scan again', 'Its document')
      end

      it 'says where it came from, with FreeAgent’s category to confirm, when it couldn’t be filed' do
        expense!(expense_id, import(vat_treatment: nil))
        get "/expenses/#{expense_id}"

        expect(last_response.body).to include('Imported from FreeAgent', 'Category on FreeAgent: ', 'Accommodation and meals')
      end

      it 'links to it on FreeAgent, when the import knows where' do
        url = 'https://example.freeagent.com/users/42/expenses/7/edit'
        expense!(expense_id, import(external_url: url))
        get "/expenses/#{expense_id}"

        expect(last_response.body).to include(%(href="#{url}"), 'Open in FreeAgent')
      end

      it 'offers a source’s own category to choose, by its name' do
        db = Sidereal.config['db']
        db.transaction(rollback: :always, auto_savepoint: true) do
          db[:categories].insert(key: 'use_of_home', label: 'Use of home', source: 'freeagent', first_seen_at: Time.now)
          body = at

          expect(body).to include('<option value="use_of_home">Use of home</option>')
        end
      end

      it 'has no link without one' do
        expect(at).not_to include('Open in FreeAgent')
      end

      it 'shows a change on FreeAgent, filed again' do
        body = at(import(description: 'Pret - Brunch', net_price_cents: 3000))

        expect(body).to include('Filed, as it is on FreeAgent', 'Pret - Brunch', '34.00 GBP')
      end
    end

    describe 'its history' do
      it 'lists its events, newest first' do
        body = at(*reviewed)

        expect(body).to include('id="history"', 'Live', 'expense_drafted', 'initial → reviewing', 'category_chosen')
        expect(body.index('category_chosen')).to be < body.index('expense_drafted')
      end

      it 'lists the commands with the events, its document’s DraftExpenseFromDocument included' do
        store.append([drafted(*scan)])
        get "/expenses/#{expense_id}"

        expect(last_response.body).to include('draft_expense_from_document')
      end

      it 'travels to a past step, frozen and not listening' do
        at(*reviewed)
        get "/expenses/#{expense_id}/at/3"

        body = last_response.body
        expect(last_response.status).to eq(200)
        expect(body).to include('Step 3 of', 'Back to live', 'record-page__frozen', 'Ready to review')
        expect(stream_channels(body)).to eq(%w[system.>])
      end

      it 'patches a past step in place for a Datastar request' do
        at
        get "/expenses/#{expense_id}/at/2", {}, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'

        expect(last_response.body).to include('datastar-patch-elements', 'Step 2 of', 'history.pushState')
      end

      it 'has no step past the last one' do
        at
        get "/expenses/#{expense_id}/at/999"

        expect(last_response.status).to eq(404)
      end

      it 'has the statechart in a Diagram tab of its own, travelling there too' do
        at
        expect(last_response.body).to include(%(href="/expenses/#{expense_id}/diagram"))
        expect(last_response.body).not_to include('class="statechart')

        get "/expenses/#{expense_id}/diagram"
        body = last_response.body
        expect(body).to include('class="statechart', 'Expense statechart', 'id="history"')
        expect(body).not_to include('file-dialog')

        get "/expenses/#{expense_id}/diagram/at/2"
        expect(last_response.body).to include('Step 2 of', 'class="statechart', %(href="/expenses/#{expense_id}/at/2"))
      end
    end

    it 'gives each browser a session' do
      get "/expenses/#{expense_id}"

      expect(last_request.env['rack.session']).to respond_to(:id)
    end
  end
end
