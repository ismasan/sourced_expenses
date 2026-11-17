# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'The expense lists' do
  include Rack::Test::Methods

  def app = App

  let(:db) { Sidereal.config['db'] }

  # Each example on an empty table, rolled back after.
  around do |example|
    db.transaction(rollback: :always, auto_savepoint: true) do
      db[:submissions].delete
      db[:ledger].delete
      example.run
    end
  end

  def submission(filename, *paths, at: Time.now, on: nil)
    SecureRandom.hex(16).tap do |expense_id|
      db[:submissions].insert(expense_id:, filename:, machine: JSON.generate(paths), incurred_on: on,
                              uploaded_at: at, updated_at: at)
    end
  end

  # A filed expense dated +on+, in the list and the ledger.
  def filed(filename, on:, cents:, paths: %w[filed filed.vat_confirmed], at: Time.now)
    submission(filename, *paths, on:, at:).tap do |expense_id|
      db[:ledger].insert(expense_id:, incurred_on: on, currency: 'EUR', amount_cents: cents, reporting_currency: 'GBP',
                         reporting_cents: cents, updated_at: Time.now)
    end
  end

  def seed
    submission('reading.pdf', 'scanning', 'scanning.extracting', at: Time.now - 60)
    submission('storing.pdf', at: Time.now - 50)
    submission('review.pdf', 'reviewing', at: Time.now - 40)
    submission('vat.pdf', 'filed', 'filed.vat_needs_review', at: Time.now - 30)
    submission('filed.pdf', 'filed', 'filed.vat_confirmed', at: Time.now - 20)
    submission('icon.png', 'rejected', at: Time.now - 10)
    submission('gone.pdf', 'discarded', at: Time.now)
  end

  def filenames(body) = body.scan(/class="submission__file">([^<]+)</).flatten

  describe Expenses::Submissions do
    it 'counts every row in exactly one state' do
      seed

      expect(Expenses::Submissions.counts(db)).to eq(
        'scanning' => 2, 'reviewing' => 1, 'rejected' => 1, 'scan_failed' => 0,
        'vat_needs_review' => 1, 'filed' => 1, 'discarded' => 1, 'voided' => 0
      )
    end

    it 'pages through the rows in any of the states, newest first' do
      seed

      rows, total = Expenses::Submissions.page(db, states: Expenses::Submissions::NEEDS_YOU, per_page: 2)
      expect([rows.map(&:filename), total]).to eq([%w[icon.png vat.pdf], 3])
      rows, = Expenses::Submissions.page(db, states: Expenses::Submissions::NEEDS_YOU, page: 2, per_page: 2)
      expect(rows.map(&:filename)).to eq(%w[review.pdf])
    end
  end

  it 'shows only what needs a person on the home page' do
    seed
    get '/'

    expect(filenames(last_response.body)).to eq(%w[icon.png vat.pdf review.pdf])
  end

  it "shows this month's total in the reporting currency on the home page too" do
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: Date.today, currency: 'EUR', amount_cents: 2420,
                       reporting_currency: 'GBP', reporting_cents: 2113, updated_at: Time.now)
    get '/'

    expect(last_response.body).to include('id="ledger-total"', Date.today.strftime('%B %Y'), '21.13 GBP', '1 expense filed')
  end

  it 'says so when nothing needs a person' do
    submission('filed.pdf', 'filed', 'filed.vat_confirmed')
    get '/'

    expect(last_response.body).to include('Nothing needs you right now')
  end

  it 'lists every expense, newest first' do
    seed
    get '/expenses'

    expect(filenames(last_response.body)).to eq(%w[gone.pdf icon.png filed.pdf vat.pdf review.pdf storing.pdf reading.pdf])
    expect(last_response.body).to include('1–7 of 7')
  end

  it 'filters by state, and keeps the filter in the params signal for live updates' do
    seed
    get '/expenses?state[]=scanning&state[]=filed'

    expect(filenames(last_response.body)).to eq(%w[filed.pdf storing.pdf reading.pdf])
    expect(last_response.body).to include('value="scanning" checked', 'value="filed" checked', 'Clear filters')
    expect(last_response.body).to include('&quot;params&quot;:{&quot;state&quot;:[&quot;scanning&quot;,&quot;filed&quot;]}')
  end

  it "shows this month's total in the reporting currency" do
    today = Date.today
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: today, currency: 'EUR', amount_cents: 2420,
                       reporting_currency: 'GBP', reporting_cents: 2113, updated_at: Time.now)
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: today, currency: 'GBP', amount_cents: 120_000, updated_at: Time.now)
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: today, currency: 'SEK', amount_cents: 9900, updated_at: Time.now)
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: today, currency: 'EUR', amount_cents: 1000,
                       reporting_currency: 'USD', reporting_cents: 1161, updated_at: Time.now)
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: today.prev_month, currency: 'GBP', amount_cents: 500,
                       updated_at: Time.now)
    get '/expenses'

    expect(last_response.body).to include(today.strftime('%B %Y'), '1,221.13 GBP', '4 expenses filed, 2 not in GBP yet')
  end

  it 'refuses a state it does not know, or a page below 1' do
    get '/expenses?state[]=bogus'
    expect(last_response.status).to eq(400)

    get '/expenses?page=0'
    expect(last_response.status).to eq(400)
  end

  it 'pages, keeping the filter in the links' do
    30.times { |i| submission("r#{i}.pdf", 'reviewing', at: Time.now - i) }
    get '/expenses?state[]=reviewing&page=2'

    expect(filenames(last_response.body)).to eq(%w[r25.pdf r26.pdf r27.pdf r28.pdf r29.pdf])
    expect(last_response.body).to include('26–30 of 30', 'Page 2 of 2', 'href="/expenses?state[]=reviewing" rel="prev"')
  end

  it 'shows the last page for one past the end' do
    30.times { |i| submission("r#{i}.pdf", 'reviewing', at: Time.now - i) }
    get '/expenses?page=9'

    expect(last_response.body).to include('26–30 of 30', 'Page 2 of 2')
  end

  describe 'by date' do
    let(:nov) { Date.new(2025, 11, 1) }

    before do
      filed('early.pdf', on: nov + 2, cents: 1000, at: Time.now - 40)
      filed('vat.pdf', on: nov + 9, cents: 5000, paths: %w[filed filed.vat_needs_review], at: Time.now - 30)
      filed('late.pdf', on: nov + 20, cents: 2000, at: Time.now - 20)
      filed('december.pdf', on: Date.new(2025, 12, 3), cents: 4000, at: Time.now - 10)
      submission('reading.pdf', 'scanning', 'scanning.extracting')
    end

    it 'lists those dated in the range, leaving out ones with no date yet' do
      get '/expenses?from=2025-11-01&to=2025-11-30'

      expect(filenames(last_response.body)).to eq(%w[late.pdf vat.pdf early.pdf])
      expect(last_response.body).to include('<option value="2025-11-01/2025-11-30" selected>November 2025</option>')
    end

    it 'takes a range open at either end' do
      get '/expenses?from=2025-11-15'
      expect(filenames(last_response.body)).to eq(%w[december.pdf late.pdf])

      get '/expenses?to=2025-11-15'
      expect(filenames(last_response.body)).to eq(%w[vat.pdf early.pdf])
      expect(last_response.body).to include('Custom dates')
    end

    it 'takes emptied date fields as no dates' do
      get '/expenses?from=&to=&state[]=filed'

      expect(last_response.status).to eq(200)
      expect(filenames(last_response.body)).to eq(%w[december.pdf late.pdf early.pdf])
    end

    it 'lists nothing for a range that ends before it starts' do
      get '/expenses?from=2025-11-30&to=2025-11-01'

      expect(last_response.body).to include('No expenses match the filters')
    end

    it 'refuses a date that is not YYYY-MM-DD' do
      get '/expenses?from=1%20Nov%202025'

      expect(last_response.status).to eq(400)
    end

    it 'counts the states in the range' do
      get '/expenses?from=2025-11-01&to=2025-11-30'

      expect(last_response.body).to match(%r{value="filed"[^>]*>.*?filter__count">2<}m)
    end

    it 'totals every filed expense in the range, in the reporting currency, whatever the states' do
      ['', 'state[]=filed&', 'state[]=scanning&'].each do |states|
        get "/expenses?#{states}from=2025-11-01&to=2025-11-30"

        expect(last_response.body).to include('id="ledger-total"', 'November 2025', '80.00 GBP', '3 expenses filed')
      end
    end

    it 'names a range that is not a whole month' do
      get '/expenses?from=2025-11-02&to=2025-11-21'
      expect(last_response.body).to include('2 Nov 2025 – 21 Nov 2025', '80.00 GBP')

      get '/expenses?from=2025-11-15'
      expect(last_response.body).to include('Since 15 Nov 2025', '60.00 GBP')
    end

    it "shows this month's total without dates" do
      get '/expenses?state[]=filed'

      expect(last_response.body).to include(Date.today.strftime('%B %Y'), '0.00 GBP')
    end

    it 'keeps the dates in the pager' do
      30.times { |i| filed("r#{i}.pdf", on: nov + 1, cents: 100, at: Time.now - 100 - i) }
      get '/expenses?state[]=filed&from=2025-11-01&to=2025-11-30'

      expect(last_response.body).to include('href="/expenses?state[]=filed&from=2025-11-01&to=2025-11-30&page=2" rel="next"')
    end
  end
end
