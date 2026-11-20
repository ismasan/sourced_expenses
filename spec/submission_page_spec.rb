# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'A submission' do
  include Rack::Test::Methods

  def app = App

  let(:store) { Sidereal.config['sourced.store'] }
  let(:file_store) { Sidereal.config['file_store'] }
  let(:expense_id) { SecureRandom.hex(16) }
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
  let(:start) { cmd(Expenses::Expense::StartScan) }
  let(:scanned) do
    [upload, start, cmd(Expenses::Expense::Scanning::CompletePreparation, processed_file_ref: jpeg), cmd(Expenses::Expense::Scanning::CompleteExtraction, **extraction),
     cmd(Expenses::Expense::Scanning::CompleteCleanup, description: 'Café Central — Lunch', tax_description: 'BTW 21%')]
  end

  # Category chosen and VAT confirmed: ready to file.
  let(:reviewed) do
    [*scanned, cmd(Expenses::Expense::ChooseCategory, category: 'travel'),
     cmd(Expenses::Expense::ConfirmVatTreatment, treatment: 'domestic')]
  end

  it 'shows the suggested category in review, with every category to choose from' do
    body = at(*scanned, cmd(Expenses::Expense::SuggestCategory, category: 'business_entertaining', probability: 0.82,
                                                                description: 'Café Central — Lunch'))

    expect(body).to include('Suggested category: ', '<strong>Business entertaining</strong>', '82% sure',
                            'value="business_entertaining" title="Meals, drinks, gifts or events for clients, prospects or suppliers" selected', '>Light, heat and power</option>')
    # A suggestion looks unconfirmed until a person confirms it.
    expect(body).to include('category__form category__form--suggested',
                            '<button type="submit" class="button button--primary button--suggested">Confirm</button>')
  end

  it 'shows a filed expense’s chosen category' do
    form = { description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420, currency: 'EUR', incurred_on: Date.new(2026, 8, 9) }
    body = at(*reviewed, cmd(Expenses::Expense::SaveExpense, **form))

    expect(body).to include('Category: <strong>Travel</strong>', 'Change</button>')
    expect(body).not_to include('button--suggested', 'category__form--suggested')
  end

  it 'has the category in its history, on the Diagram tab and travelling back' do
    history = decided(Expenses::Expense, { expense_id: }, *scanned,
                      cmd(Expenses::Expense::FailCategorization, description: 'Café Central — Lunch', reason: 'OpenAI is rate limiting requests'),
                      cmd(Expenses::Expense::ChooseCategory, category: 'business_entertaining'))
    store.append(history)

    get "/submissions/#{expense_id}/diagram"
    expect(last_response.body).to include('categorization_failed', 'category_chosen', 'category: business_entertaining')

    failed = history.index { it.is_a?(Expenses::Expense::CategorizationFailed) } + 1
    get "/submissions/#{expense_id}/at/#{failed}"
    expect(last_response.body).to include('No category suggested: ', 'OpenAI is rate limiting requests')
    expect(last_response.body).not_to include('Category: <strong>')
  end

  it 'shows "Uploading…" before the machine has the upload' do
    get "/submissions/#{expense_id}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Uploading…', 'tabs__tab')
  end

  it 'shows the step, the thumbnail and the live statechart while scanning' do
    body = at(upload, start)

    expect(body).to include('Preparing the file…', "/files/#{jpeg}/thumbnail", 'file-dialog', 'Discard')
    expect(body).not_to include('callout--attention')
    expect(body).not_to include('Save expense')
  end

  it 'has the statechart in a Diagram tab of its own' do
    at(upload, start)
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

  it 'asks for the category and the VAT treatment before the form, with what the scan read' do
    body = at(*scanned)

    expect(body).to include('<p class="panel-lead callout--attention">')
    expect(body).to include('Ready to review', 'Café Central — Lunch', '24.20 EUR', 'Suggested VAT treatment: ',
                            '<strong>Domestic</strong>', 'Choose a category', 'Scan again')
    expect(body).not_to include('File expense', 'value="2000"')
    # The suggested treatment isn't chosen yet: choosing it confirms it.
    expect(body).to match(%r{<button type="submit" class="button button--primary button--suggested" aria-pressed="false">Confirm Domestic</button>})
    expect(body).not_to include('button--selected')
  end

  it 'flags another country’s VAT for a closer look' do
    expect(at(*scanned[0..2], cmd(Expenses::Expense::Scanning::CompleteExtraction, **extraction, supplier_country_code: 'DE'),
              scanned.last)).to include('<strong>Foreign VAT</strong>', 'Another country’s VAT: check it closely.')
  end

  it 'keeps a step done in view, to change, while the other waits' do
    body = at(*scanned, cmd(Expenses::Expense::ConfirmVatTreatment, treatment: 'import'))

    expect(body).to include('Ready to review', 'VAT treatment: <strong>Import</strong>', 'Choose a category')
    expect(body).to match(%r{<button type="submit" disabled class="button button--selected" aria-pressed="true">Import</button>})
  end

  it 'prefills the form from the scan once reviewed' do
    body = at(*reviewed)

    expect(body).to include('Ready to file', 'File expense', 'value="Café Central — Lunch"', 'value="2000"',
                            'value="420"', 'value="2026-08-09"', 'Scan again')
  end

  it 'files it last, after the two steps, beside the other ways out' do
    body = at(*reviewed)
    file = body.index('<button type="submit" form="review-form" class="button button--primary">File expense</button>')

    expect(body).to include('<form class="review-form" id="review-form"')
    expect(file).to be > body.index('aria-label="VAT treatment"')
    expect(file).to be > body.index('aria-label="Category"')
    expect(body.index('>Scan again</button>')).to be > file
    expect(body[body.index('id="review-form"')...file]).not_to include('File expense')
  end

  it 'files the expense the form posts' do
    at(*reviewed)
    post '/commands', command: { type: Expenses::Expense::SaveExpense.type, _cid: 'x', payload: {
      expense_id:, description: 'Lunch', net_price_cents: '2000', tax_amount_cents: '420', tax_description: 'BTW 21%',
      currency: 'EUR', incurred_on: '2026-08-09', supplier_country_code: 'NL', reverse_charge: '0', payment_reference: ''
    } }

    saved = store.read_all(limit: 10_000).to_a.reverse.find { it.is_a?(Expenses::Expense::SaveExpense) }
    expect(saved.payload).to have_attributes(expense_id:, net_price_cents: 2000, payment_reference: nil)
  end

  it 'shows a filed expense with its VAT treatment' do
    body = at(*reviewed, cmd(Expenses::Expense::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420,
                                             currency: 'EUR', incurred_on: Date.new(2026, 8, 9), supplier_country_code: 'NL'))

    expect(body).to include('Filed', '24.20 EUR', 'VAT treatment: <strong>Domestic</strong>', 'Correct it', 'Void')
    # The confirmed treatment is chosen already; another changes it.
    expect(body).to match(%r{<button type="submit" disabled class="button button--selected" aria-pressed="true">Domestic</button>})
    expect(body).to match(%r{<button type="submit" class="button" aria-pressed="false">Import</button>})
  end

  describe 'the total in the reporting currency' do
    let(:save) do
      cmd(Expenses::Expense::SaveExpense, description: 'Lunch', net_price_cents: 2000, tax_amount_cents: 420,
                                          currency: 'EUR', incurred_on: Date.new(2026, 8, 7), supplier_country_code: 'NL')
    end

    it 'is on its way once filed' do
      expect(at(*reviewed, save)).to include('In GBP', 'Converting…')
    end

    it 'shows once converted, with the rate' do
      converted = cmd(Expenses::Expense::RecordConversion, currency: 'EUR', amount_cents: 2420, incurred_on: Date.new(2026, 8, 7),
                                                           reporting_currency: 'GBP', reporting_cents: 2113, rate: 0.8731,
                                                           rate_date: Date.new(2026, 8, 7))

      expect(at(*reviewed, save, converted)).to include('21.13 GBP', 'at 0.8731 on 7 Aug 2026')
    end
  end

  it 'lists its history, newest first' do
    body = at(*scanned)

    expect(body).to include('id="history"', 'Live', 'document_uploaded', 'runtime.scanning', 'extraction_recorded',
                            'description: Café Central - Lunch', 'initial → queued', 'queued → scanning')
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
    expect(last_response.body).to include('Step 3 of', 'Waiting to be read…')

    get "/submissions/#{expense_id}/at/4"
    body = last_response.body
    expect(last_response.status).to eq(200)
    expect(body).to include('Step 4 of', 'Back to live', 'Preparing the file…', 'submission-page__frozen')
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
