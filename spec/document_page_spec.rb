# frozen_string_literal: true

require 'rack/test'
require_relative 'page_helpers'

# Inside Expenses, so the machines read by their own names.
module Documents
  RSpec.describe UI::DocumentPage do
    include Rack::Test::Methods
    include PageHelpers

    def app = App

    def ecmd(klass, **payload) = klass.new(payload: { expense_id: document_id, **payload })

    # The document after +commands+, and its expense after +expense+, if any.
    def at(*commands, expense: [])
      document!(*commands)
      expense!(document_id, *expense) if expense.any?
      get "/documents/#{document_id}"
      last_response.body
    end

    # An extraction that doesn't add up, so verifying asks if it's a receipt.
    let(:verifying) do
      [upload, start, dcmd(Document::Scanning::CompletePreparation, processed_file_ref: jpeg),
       dcmd(Document::Scanning::CompleteExtraction, **extraction, total_amount: nil)]
    end
    let(:rejected) do
      [*verifying, dcmd(Document::Scanning::CompleteVerification, is_invoice_or_receipt: false, explanation: 'A menu, not a bill')]
    end
    let(:failed) { [upload, start, dcmd(Document::Scanning::FailPreparation, reason: 'Corrupt file')] }

    it 'shows "Uploading…" before the machine has the upload' do
      get "/documents/#{document_id}"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Uploading…', 'tabs__tab')
    end

    it 'refuses an id that is not a document’s' do
      get "/documents/#{SecureRandom.uuid}"

      expect(last_response.status).to eq(400)
    end

    it 'shows the step and the thumbnail while scanning, with discarding the only way out' do
      body = at(upload, start)

      expect(body).to include('lunch.jpg', 'Preparing the file…', "/files/#{jpeg}/thumbnail", 'file-dialog', '>Discard</button>')
      expect(body).not_to include('callout--attention', 'Scan again', 'Fill in by hand')
    end

    it 'shows why it was rejected, offering to fill it in by hand first' do
      body = at(*rejected)

      expect(body).to include('Not a receipt', 'A menu, not a bill', 'Fill in by hand', 'Scan again', 'Discard')
      expect(body.index('>Fill in by hand</button>')).to be < body.index('>Scan again</button>')
      expect(body).to include(%(value="#{Document::EnterManually.type}"))
    end

    it 'shows why its scan failed, offering to scan it again first' do
      body = at(*failed)

      expect(body).to include('Scan failed', 'Corrupt file', 'Fill in by hand')
      expect(body.index('>Scan again</button>')).to be < body.index('>Fill in by hand</button>')
    end

    it 'says its expense is on its way, once read and before it’s drafted' do
      body = at(*scan)

      expect(body).to include('Read', 'Drafting its expense…', 'Scan again', 'Discard')
      expect(body).not_to include('Fill in by hand', 'Review it')
    end

    it 'links to its expense once drafted, to review' do
      body = at(*scan, expense: [drafted(*scan)])

      expect(body).to include('Its expense: ', %(href="/expenses/#{document_id}"), 'Café Central — Lunch', 'Ready to review',
                              '>Review it</a>', 'Scan again')
    end

    it 'links to its expense filled in by hand' do
      body = at(*rejected, dcmd(Document::EnterManually), expense: [ecmd(Expenses::Expense::DraftExpenseFromDocument, document_id:, filing_country: 'NL')])

      expect(body).to include('Filled in by hand', 'Its expense, to fill in by hand: ', 'New expense', %(href="/expenses/#{document_id}"))
      expect(body).not_to include('>Fill in by hand</button>')
    end

    # Filling it in by hand drafts it empty: its expense's draft would go.
    it 'keeps its expense’s draft when a rescan fails, not offering to fill it in by hand' do
      body = at(*scan, dcmd(Document::Rescan, reference_date: Date.new(2026, 8, 11)), start,
                dcmd(Document::Scanning::FailPreparation, reason: 'Corrupt file'), expense: [drafted(*scan)])

      expect(body).to include('Scan failed', 'Corrupt file', 'Its expense: ', 'Café Central — Lunch', '>Scan again</button>')
      expect(body).not_to include('>Fill in by hand</button>')
    end

    it 'no longer offers to scan it again once its expense is filed' do
      save = ecmd(Expenses::Expense::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR',
                                        incurred_on: Date.new(2026, 8, 9))
      body = at(*scan, expense: [drafted(*scan), ecmd(Expenses::Expense::ChooseCategory, category: 'travel'),
                                 ecmd(Expenses::Expense::ConfirmVatTreatment, treatment: 'domestic'), save])

      expect(body).to include('Its expense: ', 'Filed', '>Discard</button>')
      expect(body).not_to include('Scan again', 'Review it')
    end

    it 'says so once discarded' do
      expect(at(upload, dcmd(Document::DiscardDocument))).to include('This upload was discarded')
    end

    it 'follows its own channel and its expense’s' do
      body = at(upload, start)

      expect(stream_channels(body)).to eq(["documents.#{document_id}", "expenses.#{document_id}", 'system.>'])
    end

    describe 'its history' do
      it 'lists its events, newest first' do
        body = at(*scan)

        expect(body).to include('id="history"', 'Live', 'document_uploaded', 'runtime.scanning', 'extraction_recorded',
                                'description: Café Central - Lunch', 'initial → queued', 'queued → scanning')
        expect(body.index('text_cleaned')).to be < body.index('document_uploaded')
      end

      it 'lists the commands with the events' do
        store.append([upload])
        get "/documents/#{document_id}"

        expect(last_response.body).to include('upload_document')
      end

      it 'travels to a past step, frozen and not listening' do
        at(*scan)
        get "/documents/#{document_id}/at/3"
        expect(last_response.body).to include('Step 3 of', 'Waiting to be read…')

        get "/documents/#{document_id}/at/4"
        body = last_response.body
        expect(last_response.status).to eq(200)
        expect(body).to include('Step 4 of', 'Back to live', 'Preparing the file…', 'record-page__frozen')
        expect(stream_channels(body)).to eq(%w[system.>])
      end

      it 'patches a past step in place for a Datastar request' do
        at(*scan)
        get "/documents/#{document_id}/at/2", {}, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'

        expect(last_response.body).to include('datastar-patch-elements', 'Step 2 of', 'history.pushState')
      end

      it 'has no step past the last one' do
        at(*scan)
        get "/documents/#{document_id}/at/999"

        expect(last_response.status).to eq(404)
      end

      it 'has the statechart in a Diagram tab of its own, travelling there too' do
        at(upload, start)
        expect(last_response.body).to include(%(href="/documents/#{document_id}/diagram"))

        get "/documents/#{document_id}/diagram"
        body = last_response.body
        expect(body).to include('class="statechart', 'Document statechart', 'Preparing the file…', 'id="history"')
        expect(body).not_to include('file-dialog', '>Discard</button>')

        get "/documents/#{document_id}/diagram/at/2"
        expect(last_response.body).to include('Step 2 of', 'class="statechart', %(href="/documents/#{document_id}/at/2"))
      end
    end

    describe 'its file' do
      it 'is served, with its thumbnail' do
        get "/files/#{jpeg}"
        expect(last_response.headers['content-type']).to eq('image/jpeg')

        get "/files/#{jpeg}/thumbnail"
        expect(last_response.status).to eq(200)
        expect(last_response.body.b).to start_with("\xFF\xD8".b)

        get "/files/#{'0' * 32}"
        expect(last_response.status).to eq(404)
      end

      it 'is streamed from disk, a byte range of it when asked' do
        path = file_store.read(jpeg).path
        _status, headers, body = App.call(Rack::MockRequest.env_for("/files/#{jpeg}"))
        # Not read into memory: the server sends it from the file.
        expect(body.to_path).to eq(path)
        expect(headers['content-length']).to eq(File.size(path).to_s)
        body.close if body.respond_to?(:close)

        get "/files/#{jpeg}", {}, 'HTTP_RANGE' => 'bytes=0-1'
        expect(last_response.status).to eq(206)
        expect(last_response.headers['content-range']).to eq("bytes 0-1/#{File.size(path)}")
        expect(last_response.body.b).to eq("\xFF\xD8".b)
      end
    end
  end
end
