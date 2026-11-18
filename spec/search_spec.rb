# frozen_string_literal: true

require 'rack/test'
require 'sourced/testing/rspec'

RSpec.describe 'Searching expenses' do
  include Rack::Test::Methods
  include Sourced::Testing::RSpec

  def app = App

  let(:db) { Sidereal.config['db'] }

  # Each example on empty tables, rolled back after.
  around do |example|
    db.transaction(rollback: :always, auto_savepoint: true) do
      db[:submissions].delete
      db[:submissions_search].delete
      db[:ledger].delete
      example.run
    end
  end

  # A filed expense in the list, the index and the ledger, as the
  # projectors leave them.
  def expense(description, vendor: nil, category: nil, cents: 1000, on: Date.today, at: Time.now)
    SecureRandom.hex(16).tap do |expense_id|
      row = { expense_id:, filename: "#{description.downcase.tr(' ', '-')}.pdf", machine: '["filed"]',
              description:, vendor:, category:, total_cents: cents, currency: 'GBP', incurred_on: on,
              uploaded_at: at, updated_at: at }
      db[:submissions].insert(row)
      db[:submissions_search].insert(expense_id:, body: Expenses::Submissions.search_body(row))
      db[:ledger].insert(expense_id:, incurred_on: on, currency: 'GBP', amount_cents: cents, category:, updated_at: at)
    end
  end

  def found(text) = Expenses::Submissions.in_states(db, search: text).select_map(:description).sort

  describe Expenses::Submissions do
    let(:expense_id) { SecureRandom.hex(16) }
    let(:date) { Date.new(2025, 10, 24) }

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

    def project(*commands)
      decided(Expenses::Expense, { expense_id: }, *commands)
        .reduce(with_reactor(Expenses::Submissions, expense_id:)) { |r, m| r.given(m) }.then! { nil }
    end

    let(:scanned) do
      [cmd(Expenses::Expense::UploadDocument, filename: 'receipt-0042.pdf', content_type: 'application/pdf', file_ref: 'f1',
                                              filing_country: 'NL', reference_date: date),
       cmd(Expenses::Expense::Scanning::CompletePreparation, processed_file_ref: 'f1'),
       cmd(Expenses::Expense::Scanning::CompleteExtraction,
           document_type: 'receipt', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0, tax_amount: 4.2,
           tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '24 Oct 2025', date: '2025-10-24',
           vendor_name: 'Horeca Holding BV', confidence: 'high', supplier_country_code: 'NL', reverse_charge: false),
       cmd(Expenses::Expense::Scanning::CompleteCleanup, description: 'Café Central - Lunch', tax_description: 'BTW 21%')]
    end

    it 'indexes what the scan read, the vendor, the filename and the category, as they change' do
      project(*scanned, cmd(Expenses::Expense::ChooseCategory, category: 'business_entertaining'))

      expect([found('horeca'), found('0042'), found('entertaining'), found('lunch')]).to all(eq(['Café Central - Lunch']))

      project(*scanned, cmd(Expenses::Expense::ChooseCategory, category: 'business_entertaining'),
              cmd(Expenses::Expense::ConfirmVatTreatment, treatment: 'domestic'),
              cmd(Expenses::Expense::SaveExpense, description: 'Team dinner', net_price_cents: 2000, tax_amount_cents: 420,
                                                           currency: 'EUR', incurred_on: date, supplier_country_code: 'NL'))
      expect(found('lunch')).to be_empty
      expect(found('dinner')).to eq(['Team dinner'])
      expect(db[:submissions_search].where(expense_id:).count).to eq(1)
    end

    it 'empties the index when its group is reset' do
      project(*scanned)

      Expenses::Submissions.on_reset

      expect(db[:submissions_search].count).to eq(0)
    end

    describe '.search' do
      before do
        expense('Café Central - Lunch', vendor: 'Horeca Holding BV')
        expense('Uber - Trip to airport', vendor: 'Uber BV', category: 'travel')
        expense('C++ book, 50% off', vendor: 'O"Reilly')
      end

      it 'finds every word anywhere, as any part of a word, whatever its case or accents' do
        expect(found('UBER')).to eq(['Uber - Trip to airport'])
        expect(found('trip uber')).to eq(['Uber - Trip to airport'])
        expect(found('uber lunch')).to be_empty
        expect(found('cafe')).to eq(['Café Central - Lunch'])
        expect(found('holding')).to eq(['Café Central - Lunch'])
        expect(found('travel')).to eq(['Uber - Trip to airport'])
      end

      it 'finds words shorter than the index can, as plain text' do
        expect(found('ub')).to eq(['Uber - Trip to airport'])
        expect(found('lunch al')).to eq(['Café Central - Lunch'])
      end

      it 'takes anything typed as text to find, never as query syntax' do
        expect(found('C++')).to eq(['C++ book, 50% off'])
        expect(found('50%')).to eq(['C++ book, 50% off'])
        expect(found('"')).to eq(['C++ book, 50% off'])
        expect(found('o"reilly')).to eq(['C++ book, 50% off'])
        expect(found('-uber')).to be_empty
        expect(found('NOT uber')).to be_empty
        expect(found('%')).to eq(['C++ book, 50% off'])
        expect(found('_')).to be_empty
      end

      it 'is no filter for blank text' do
        expect(Expenses::Submissions.search(db, '  ')).to be_nil
        expect(found(nil).size).to eq(3)
      end
    end
  end

  describe 'the list' do
    before do
      expense('Uber - Trip', category: 'travel', cents: 1800, at: Time.now - 10)
      expense('Uber Eats - Lunch', category: 'accommodation_and_meals', cents: 1200)
      expense('Hetzner - Server', category: 'software', cents: 3000)
    end

    def descriptions = last_response.body.scan(/class="submission__description">([^<]+)</).flatten

    it 'lists only the matches, counted and totalled in the header and the chart, saying what it searched for' do
      get '/expenses?q=uber'

      expect(descriptions).to eq(['Uber Eats - Lunch', 'Uber - Trip'])
      expect(last_response.body).to include('1–2 of 2', ' matching <strong>“uber”</strong>', 'Clear search',
                                            'ledger-total__search">“uber”</span> · ', 'ledger-total__amount">30.00 GBP<')
      expect(last_response.body).to include('>Travel</span><span class="filter__count">1<')
    end

    it 'keeps the search with the other filters, in the chart’s links, the pager’s and the form' do
      get '/expenses?q=uber%20trip&category[]=travel'

      expect(descriptions).to eq(['Uber - Trip'])
      expect(last_response.body).to include('name="q" value="uber trip"', 'q=uber+trip&from=',
                                            '&quot;q&quot;:&quot;uber trip&quot;')
      expect(UI::ExpensesPage.path_for(search: 'a&b c', page: 2)).to eq('/expenses?q=a%26b+c&page=2')
    end

    it 'shows what it searched for in the search box there, and nowhere else' do
      get '/expenses?q=uber'
      expect(last_response.body).to include('id="search-q"', 'value="uber"')

      get '/'
      expect(last_response.body).to include('id="search-q"')
      expect(last_response.body).not_to include('value="uber"')
    end

    it 'takes a blank search as none' do
      get '/expenses?q=%20'

      expect(descriptions.size).to eq(3)
      expect(last_response.body).not_to include('Clear search')
    end
  end

  describe 'the preview' do
    def preview(query)
      get '/search', { q: query }, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'
      last_response.body.force_encoding(Encoding::UTF_8)
    end

    it 'patches the first few matches into the pane, newest first, with a link to them all' do
      8.times { |i| expense("Uber trip #{i}", at: Time.now + i) }
      expense('Hetzner - Server')

      body = preview('uber')

      expect(body).to include('datastar-patch-elements', 'id="search-preview"', 'See all 8 in the list', 'href="/expenses?q=uber"',
                                  'id="search-result-0"', 'id="search-result-5"', 'id="search-result-all"')
      expect(body.scan(/search-preview__description">([^<]+)</).flatten).to eq((2..7).map { "Uber trip #{it}" }.reverse)
    end

    it 'says when nothing matches' do
      expect(preview('nothing')).to include('Nothing matches <strong>“nothing”</strong>')
    end

    it 'sends any other request to the list' do
      get '/search', q: 'uber trip'

      expect(last_response.status).to eq(303)
      expect(last_response.headers['location']).to eq('/expenses?q=uber+trip')
    end
  end
end
