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
      db[:usd_ledger].delete
      example.run
    end
  end

  def submission(filename, *paths, at: Time.now)
    db[:submissions].insert(expense_id: SecureRandom.uuid, filename:, machine: JSON.generate(paths),
                            uploaded_at: at, updated_at: at)
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

  it "shows this month's total in US dollars on the home page too" do
    db[:usd_ledger].insert(expense_id: SecureRandom.uuid, incurred_on: Date.today, currency: 'EUR', amount_cents: 2420,
                           usd_cents: 2810, updated_at: Time.now)
    get '/'

    expect(last_response.body).to include('id="month-total"', Date.today.strftime('%B %Y'), '28.10 USD', '1 expense filed')
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

  it "shows this month's total in US dollars" do
    today = Date.today
    db[:usd_ledger].insert(expense_id: SecureRandom.uuid, incurred_on: today, currency: 'EUR', amount_cents: 2420, usd_cents: 2810,
                           updated_at: Time.now)
    db[:usd_ledger].insert(expense_id: SecureRandom.uuid, incurred_on: today, currency: 'USD', amount_cents: 120_000,
                           usd_cents: 120_000, updated_at: Time.now)
    db[:usd_ledger].insert(expense_id: SecureRandom.uuid, incurred_on: today, currency: 'SEK', amount_cents: 9900, updated_at: Time.now)
    db[:usd_ledger].insert(expense_id: SecureRandom.uuid, incurred_on: today.prev_month, currency: 'USD', amount_cents: 500,
                           usd_cents: 500, updated_at: Time.now)
    get '/expenses'

    expect(last_response.body).to include(today.strftime('%B %Y'), '1,228.10 USD', '3 expenses filed, 1 not in US dollars yet')
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
end
