# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'A submission' do
  include Rack::Test::Methods

  def app = App

  let(:store) { Sidereal.config['sourced.store'] }
  let(:file_store) { Sidereal.config['file_store'] }
  let(:expense_id) { SecureRandom.uuid }
  let(:jpeg) do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'r.jpg')
      system('magick', '-size', '300x400', 'xc:white', path, exception: true)
      File.open(path, 'rb') { file_store.put('lunch.jpg', it) }
    end
  end

  let(:extraction) do
    { document_type: 'invoice', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0,
      tax_amount: 4.2, tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '9 Aug 2026', date: '2026-08-09',
      vendor_name: 'Café Central', confidence: 'high', supplier_country_code: 'NL', reverse_charge: false }
  end

  def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

  def at(*commands)
    store.append(decided(Expenses::Expense, { expense_id: }, *commands))
    get "/submissions/#{expense_id}"
    last_response.body
  end

  let(:upload) do
    cmd(Expenses::Expense::UploadDocument, filename: 'lunch.jpg', content_type: 'image/jpeg', file_ref: jpeg, filing_country: 'NL',
                           reference_date: Date.new(2026, 8, 11))
  end
  let(:scanned) do
    [upload, cmd(Expenses::Expense::Scanning::CompletePreparation, processed_file_ref: jpeg), cmd(Expenses::Expense::Scanning::CompleteExtraction, **extraction),
     cmd(Expenses::Expense::Scanning::CompleteCleanup, description: 'Café Central — Lunch', tax_description: 'BTW 21%')]
  end

  it 'shows "Uploading…" before the machine has the upload' do
    get "/submissions/#{expense_id}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Uploading…', 'tabs__tab')
  end

  it 'shows the step, the thumbnail and the live statechart while scanning' do
    body = at(upload)

    expect(body).to include('Preparing the file…', "/files/#{jpeg}/thumbnail", 'file-dialog', 'Discard')
    expect(body).not_to include('Save expense')
  end

  it 'has the statechart in a Diagram tab of its own' do
    at(upload)
    expect(last_response.body).to include(%(href="/submissions/#{expense_id}/diagram"))
    expect(last_response.body).not_to include('class="statechart')

    get "/submissions/#{expense_id}/diagram"
    body = last_response.body
    expect(body).to include('class="statechart', 'Preparing the file…', 'id="history"', "/updates/expenses.#{expense_id}")
    expect(body).not_to include('file-dialog', '>Discard</button>')
    expect(body).to include(%(href="/submissions/#{expense_id}/diagram/at/1"))
  end

  it 'travels on the Diagram tab, with the other tab at the same step' do
    at(*scanned)
    get "/submissions/#{expense_id}/diagram/at/4"

    body = last_response.body
    expect(body).to include('Step 4 of', 'class="statechart', %(href="/submissions/#{expense_id}/at/4"))
  end

  it 'prefills the review form from the scan' do
    body = at(*scanned)

    expect(body).to include('Ready to review', 'Save expense', 'value="Café Central — Lunch"', 'value="2000"',
                            'value="420"', 'value="2026-08-09"', 'Scan again')
  end

  it 'files the expense the form posts' do
    at(*scanned)
    post '/commands', command: { type: Expenses::Expense::SaveExpense.type, _cid: 'x', payload: {
      expense_id:, description: 'Lunch', net_price_cents: '2000', tax_amount_cents: '420', tax_description: 'BTW 21%',
      currency: 'EUR', incurred_on: '2026-08-09', supplier_country_code: 'NL', reverse_charge: '0', payment_reference: ''
    } }

    saved = store.read_all(limit: 10_000).to_a.reverse.find { it.is_a?(Expenses::Expense::SaveExpense) }
    expect(saved.payload).to have_attributes(expense_id:, net_price_cents: 2000, payment_reference: nil)
  end

  it 'shows a filed expense with its VAT treatment' do
    body = at(*scanned, cmd(Expenses::Expense::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420,
                                            currency: 'EUR', incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL'))

    expect(body).to include('Filed', '24.20 EUR', 'Domestic, suggested', 'Correct it', 'Void')
    # The suggested treatment is the chosen one, and still choosable: that confirms it.
    expect(body).to match(%r{<button type="submit" class="button button--selected" aria-pressed="true">Domestic</button>})
    expect(body).to match(%r{<button type="submit" class="button" aria-pressed="false">Import</button>})
  end

  describe 'the total in US dollars' do
    let(:save) do
      cmd(Expenses::Expense::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420,
                                          currency: 'EUR', incurred_on: Date.new(2026, 8, 7), supplier_country_code: 'NL')
    end

    it 'is on its way once filed' do
      expect(at(*scanned, save)).to include('In US dollars', 'Converting…')
    end

    it 'shows once converted, with the rate' do
      usd = cmd(Expenses::Expense::RecordUsdAmount, currency: 'EUR', amount_cents: 2420, incurred_on: Date.new(2026, 8, 7),
                                                    usd_cents: 2810, rate: 1.1612, rate_date: Date.new(2026, 8, 7))

      expect(at(*scanned, save, usd)).to include('28.10 USD', 'at 1.1612 on 7 Aug 2026')
    end
  end

  it 'lists its history, newest first' do
    body = at(*scanned)

    expect(body).to include('id="history"', 'Live', 'document_uploaded', 'runtime.scanning', 'extraction_recorded',
                            'description: Café Central - Lunch', 'initial → scanning')
    expect(body.index('text_cleaned')).to be < body.index('document_uploaded')
  end

  it 'lists the commands with the events' do
    store.append([upload])
    get "/submissions/#{expense_id}"

    expect(last_response.body).to include('upload_document')
  end

  it 'travels to a past step, frozen and not listening' do
    at(*scanned)
    get "/submissions/#{expense_id}/at/3"

    body = last_response.body
    expect(last_response.status).to eq(200)
    expect(body).to include('Step 3 of', 'Back to live', 'Preparing the file…', 'submission-page__frozen')
    expect(body).not_to include("/updates/expenses.#{expense_id}")
    expect(body).not_to include('Save expense')
  end

  it 'patches a past step in place for a Datastar request' do
    at(*scanned)
    get "/submissions/#{expense_id}/at/2", {}, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'

    expect(last_response.body).to include('datastar-patch-elements', 'Step 2 of', 'history.pushState')
  end

  it 'has no step past the last one' do
    at(*scanned)
    get "/submissions/#{expense_id}/at/999"

    expect(last_response.status).to eq(404)
  end

  it 'serves the file and its thumbnail' do
    get "/files/#{jpeg}"
    expect(last_response.headers['content-type']).to eq('image/jpeg')

    get "/files/#{jpeg}/thumbnail"
    expect(last_response.status).to eq(200)
    expect(last_response.body.b).to start_with("\xFF\xD8".b)

    get "/files/#{'0' * 32}"
    expect(last_response.status).to eq(404)
  end
end
