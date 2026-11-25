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
  def filed(filename, on:, cents:, paths: %w[filed], at: Time.now)
    submission(filename, *paths, on:, at:).tap do |expense_id|
      db[:ledger].insert(expense_id:, incurred_on: on, currency: 'EUR', amount_cents: cents, reporting_currency: 'GBP',
                         reporting_cents: cents, updated_at: Time.now)
    end
  end

  def seed
    submission('reading.pdf', 'scanning', 'scanning.extracting', at: Time.now - 60)
    submission('storing.pdf', at: Time.now - 50)
    submission('review.pdf', 'reviewing', at: Time.now - 40)
    submission('ready.pdf', 'reviewed', at: Time.now - 30)
    submission('filed.pdf', 'filed', at: Time.now - 20)
    submission('icon.png', 'rejected', at: Time.now - 10)
  end

  def filenames(body) = body.scan(/class="submission__file">([^<]+)</).flatten

  describe Expenses::Submissions do
    it 'counts every row in exactly one state' do
      seed

      expect(Expenses::Submissions.counts(db)).to eq(
        'scanning' => 2, 'reviewing' => 1, 'rejected' => 1, 'scan_failed' => 0,
        'reviewed' => 1, 'filed' => 1, 'voided' => 0
      )
    end

    it 'pages through the rows in any of the states, newest first' do
      seed

      rows, total = Expenses::Submissions.page(db, states: Expenses::Submissions::NEEDS_YOU, per_page: 2)
      expect([rows.map(&:filename), total]).to eq([%w[icon.png ready.pdf], 3])
      rows, = Expenses::Submissions.page(db, states: Expenses::Submissions::NEEDS_YOU, page: 2, per_page: 2)
      expect(rows.map(&:filename)).to eq(%w[review.pdf])
    end
  end

  it 'shows what is being read, then what needs a person, on the home page' do
    seed
    get '/'

    being_read, needs_you = last_response.body.split('id="needs-you"')
    expect(being_read).to include('id="being-read"', '>Being read<span class="submissions__count">2<')
    expect(filenames(being_read)).to eq(%w[storing.pdf reading.pdf])
    expect(filenames(needs_you)).to eq(%w[icon.png ready.pdf review.pdf])
  end

  it "shows the scan queue's bar along the bottom of every page while it's busy, live over the page's stream" do
    bar = %r{<section id="queue-scans" class="queue-bar"([^>]*)>}
    ['/', '/expenses'].each do |path|
      get path
      expect(last_response.body[bar, 1]).to include('hidden'), path
      expect(stream_channels(last_response.body)).to eq(%w[expenses.> system.>])
    end

    q = WorkQueue
    items = Array.new(9) { SecureRandom.hex(16) }
    start = ->(id) { { type: Expenses::Expense::StartScan.type, payload: { expense_id: id } } }
    queue = { queue_name: 'scans' }
    Sourced.store.append(items.map { q::Enqueued.new(payload: { **queue, capacity: 3, item_id: it, start: start.(it) }) } +
                         items.take(5).map { q::Started.new(payload: { **queue, item_id: it }) } +
                         items.take(2).map { q::Released.new(payload: { **queue, item_id: it }) })
    ['/', '/expenses'].each do |path|
      get path
      expect(last_response.body[bar, 1]).not_to include('hidden'), path
      expect(last_response.body).to include('3 of 3 slots in use · 4 documents waiting')
    end
  end

  it 'leaves out the list of those being read with none' do
    submission('review.pdf', 'reviewing')
    get '/'

    expect(last_response.body).to include('<div id="being-read"></div>')
    expect(last_response.body).not_to include('Being read')
  end

  it "shows this month's total in the reporting currency on the home page too" do
    db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: Date.today, currency: 'EUR', amount_cents: 2420,
                       reporting_currency: 'GBP', reporting_cents: 2113, updated_at: Time.now)
    get '/'

    expect(last_response.body).to include('id="ledger-total"', Date.today.strftime('%B %Y'), '21.13 GBP', '1 expense filed')
  end

  it 'says so when nothing needs a person' do
    submission('filed.pdf', 'filed')
    get '/'

    expect(last_response.body).to include('Nothing needs you right now')
  end

  it 'lists every expense, newest first' do
    seed
    get '/expenses'

    expect(filenames(last_response.body)).to eq(%w[icon.png filed.pdf ready.pdf review.pdf storing.pdf reading.pdf])
    expect(last_response.body).to include('1–6 of 6')
  end

  it 'shows each expense’s category, a suggestion apart from a person’s choice' do
    db[:submissions].where(expense_id: submission('uber.pdf', 'reviewing')).update(description: 'Uber - Trip', category: 'travel')
    db[:submissions].where(expense_id: submission('github.pdf', 'filed'))
                    .update(description: 'GitHub', category: 'software', category_chosen: true)
    get '/expenses'

    expect(last_response.body).to include(
      'class="submission__category submission__category--suggested" title="Suggested category">Travel<',
      'class="submission__category" title="Category">Software and web services<'
    )
  end

  describe 'by category' do
    def categorized(filename, category, *paths)
      db[:submissions].where(expense_id: submission(filename, *paths, at: Time.now - filename.size)).update(category:)
    end

    before do
      categorized('uber.pdf', 'travel', 'filed')
      categorized('train.pdf', 'travel', 'reviewing')
      categorized('github.pdf', 'software', 'filed')
      categorized('render.pdf', 'software', 'filed')
      submission('misc.pdf', 'scanning')
    end

    def count(body, label) = body[%r{>#{label}</span><span class="filter__count">(\d+)<}, 1]&.to_i

    it 'lists only the categories some expense has, each with how many' do
      get '/expenses'

      expect(count(last_response.body, 'Travel')).to eq(2)
      expect(count(last_response.body, 'Software and web services')).to eq(2)
      expect(last_response.body).not_to include('>Insurance<')
    end

    it 'filters by any of the categories ticked, within the states ticked, counting each group within the other' do
      get '/expenses?category[]=travel&category[]=insurance&state[]=filed'
      body = last_response.body

      expect(filenames(body)).to eq(%w[uber.pdf])
      expect(body).to include('value="travel" checked', 'value="insurance" checked', 'Clear filters')
      expect(count(body, 'Travel')).to eq(1)            # filed only
      expect(count(body, 'Software and web services')).to eq(2)
      expect(count(body, 'Insurance')).to eq(0)         # ticked, so listed
      expect(count(body, 'Filed')).to eq(1)             # travel only
      expect(count(body, 'Ready to review')).to eq(1)
    end

    it 'keeps the categories in the chart’s links, the pager’s and the params signal' do
      filed('ledger.pdf', on: Date.today, cents: 1000)
      get '/expenses?category[]=travel'

      expect(last_response.body).to include('category[]=travel&from=', '&quot;category&quot;:[&quot;travel&quot;]')
      expect(UI::ExpensesPage.path_for(categories: %w[travel], page: 2)).to eq('/expenses?category[]=travel&page=2')
    end

    it 'totals only the categories ticked in the header and the chart, naming them' do
      [['taxi', 'travel', 1500], ['hosting', 'software', 700]].each do |name, category, cents|
        expense_id = filed("#{name}.pdf", on: Date.today, cents:)
        db[:ledger].where(expense_id:).update(category:)
      end

      get '/expenses?category[]=travel'
      expect(last_response.body).to include('>Travel</span> · ', 'ledger-total__amount">15.00 GBP<', '1 expense filed')

      get '/expenses?category[]=travel&category[]=software'
      expect(last_response.body).to include('>2 categories</span> · ', 'title="Software and web services, Travel"',
                                            'ledger-total__amount">22.00 GBP<')

      get '/expenses'
      expect(last_response.body).not_to include('ledger-total__categories')
      expect(last_response.body).to include('ledger-total__amount">22.00 GBP<')
    end

    it 'refuses a category it does not know' do
      get '/expenses?category[]=snacks'

      expect(last_response.status).to eq(400)
    end
  end

  it 'filters by state, and keeps the filter in the params signal for live updates' do
    seed
    get '/expenses?state[]=scanning&state[]=filed'

    expect(filenames(last_response.body)).to eq(%w[filed.pdf storing.pdf reading.pdf])
    expect(last_response.body).to include('value="scanning" checked', 'value="filed" checked', 'Clear filters')
    expect(last_response.body).to include('&quot;params&quot;:{&quot;state&quot;:[&quot;scanning&quot;,&quot;filed&quot;]}')
  end

  describe 'by whose category and VAT treatment it is' do
    before do
      db[:submissions].where(expense_id: submission('uber.pdf', 'reviewing', at: Time.now - 30))
                      .update(category: 'travel', vat_treatment: 'domestic')
      db[:submissions].where(expense_id: submission('hotel.pdf', 'reviewing', at: Time.now - 20))
                      .update(category: 'travel', category_chosen: true, vat_treatment: 'foreign_vat')
      db[:submissions].where(expense_id: submission('github.pdf', 'filed', at: Time.now - 10))
                      .update(category: 'software', category_chosen: true, vat_treatment: 'import', vat_confirmed: true)
      submission('misc.pdf', 'reviewing')
    end

    def count(body, name, value) = body[%r{name="#{Regexp.escape(name)}" value="#{value}"[^>]*>.*?filter__count">(\d+)<}m, 1]&.to_i

    it 'filters by any of each group’s statuses, both groups together' do
      get '/expenses?category_status[]=chosen&vat_status[]=suggested'
      expect(filenames(last_response.body)).to eq(%w[hotel.pdf])
      expect(last_response.body).to include('value="chosen" checked', 'value="suggested" checked', 'Clear filters')

      get '/expenses?vat_status[]=suggested&vat_status[]=none'
      expect(filenames(last_response.body)).to eq(%w[misc.pdf hotel.pdf uber.pdf])
    end

    it 'counts each status within the other filters, not its own group' do
      get '/expenses?category_status[]=chosen&state[]=reviewing'
      body = last_response.body

      expect([count(body, 'category_status[]', 'suggested'), count(body, 'category_status[]', 'chosen'),
              count(body, 'category_status[]', 'none')]).to eq([1, 1, 1])
      expect([count(body, 'vat_status[]', 'suggested'), count(body, 'vat_status[]', 'confirmed'),
              count(body, 'vat_status[]', 'none')]).to eq([1, 0, 0])
    end

    it 'keeps the statuses in its links' do
      26.times { |i| submission("r#{i}.pdf", 'reviewing', at: Time.now - 100 - i) }
      get '/expenses?category_status[]=none&vat_status[]=none'

      body = last_response.body
      expect(body).to include('href="/expenses?category_status[]=none&vat_status[]=none&page=2" rel="next"')
      # The chart's months too.
      expect(body).to match(%r{class="month-chart__link" href="/expenses\?category_status\[\]=none&vat_status\[\]=none&from=})
    end

    it 'refuses a status it does not know' do
      get '/expenses?vat_status[]=maybe'

      expect(last_response.status).to eq(400)
    end
  end

  describe 'the chart' do
    # Today, for the chart's last month: 17 Nov 2026.
    before { allow(Date).to receive(:today).and_return(Date.new(2026, 11, 17)) }

    def ledger(on, cents, **row)
      db[:ledger].insert(expense_id: SecureRandom.hex(16), incurred_on: on, currency: 'GBP', amount_cents: cents,
                         updated_at: Time.now, **row)
    end

    def months(body) = body.scan(/class="month-chart__month"/).size

    it 'expands the latest year, a bar a month up to this one, each linking to its month and keeping the states' do
      ledger(Date.new(2026, 11, 2), 2420, currency: 'EUR', reporting_currency: 'GBP', reporting_cents: 2113)
      ledger(Date.new(2026, 9, 5), 1_234_500)
      get '/expenses?state[]=filed'

      body = last_response.body
      # From the first expense's month.
      expect(months(body)).to eq(3)
      expect(body).to include('Filed per month, in GBP', 'November 2026: 21.13 GBP, 1 expense', 'October 2026: 0.00 GBP, 0 expenses',
                              'href="/expenses?state[]=filed&from=2026-11-01&to=2026-11-30"', '>21<', '>12.3K<',
                              'href="/expenses?state[]=filed&from=2026-01-01&to=2026-12-31" aria-label="2026: 12,366.13 GBP, 2 expenses"')
      expect(body).not_to include('month-chart__link--chosen', 'month-chart__band--chosen', 'All dates', 'type="date"')
    end

    it 'compacts every other year into one column, linking to the year, all years on one scale' do
      ledger(Date.new(2024, 11, 5), 1000)
      ledger(Date.new(2025, 2, 5), 2500)
      ledger(Date.new(2026, 3, 1), 500)
      get '/expenses'

      body = last_response.body
      expect(months(body)).to eq(11)
      expect(body.scan('month-chart__year--compact').size).to eq(2)
      expect(body).to include('href="/expenses?from=2024-01-01&to=2024-12-31" aria-label="2024: 10.00 GBP, 1 expense"',
                              'href="/expenses?from=2025-01-01&to=2025-12-31" aria-label="2025: 25.00 GBP, 1 expense"',
                              'style="--share: 0.4"', 'style="--share: 1.0"')
      # The year expanded stands at its own level on the years' scale: 5.00 of the biggest year's 25.00.
      expect(body).to include('style="--months: 11; --level: 0.2; view-transition-name: month-chart-2026"')
      # Each year's column named for the view transition that expanding one animates.
      expect(body).to include('<li class="month-chart__year month-chart__year--compact" style="view-transition-name: month-chart-2024">',
                              '<li class="month-chart__year month-chart__year--compact" style="view-transition-name: month-chart-2025">',
                              '@view-transition { navigation: auto; }')
    end

    it 'expands the year of the month chosen, highlighted, its link going back to all dates, the dates kept for states' do
      ledger(Date.new(2025, 2, 5), 2500)
      ledger(Date.new(2026, 3, 1), 500)
      get '/expenses?state[]=filed&from=2025-02-01&to=2025-02-28'

      body = last_response.body
      expect(months(body)).to eq(11)
      expect(body).to match(%r{<a class="month-chart__link month-chart__link--chosen" href="/expenses\?state\[\]=filed"[^>]*aria-current="true"})
      expect(body).to include('aria-label="2026: 5.00 GBP, 1 expense"', '>All dates<',
                              '<input type="hidden" name="from" value="2025-02-01">', '<input type="hidden" name="to" value="2025-02-28">')
    end

    it 'expands the year chosen, its band highlighted, with the year in the header' do
      ledger(Date.new(2025, 2, 5), 2500)
      ledger(Date.new(2026, 3, 1), 500)
      get '/expenses?state[]=filed&from=2025-01-01&to=2025-12-31'

      body = last_response.body
      expect(months(body)).to eq(11)
      expect(body).to match(%r{<a class="month-chart__band month-chart__band--chosen" href="/expenses\?state\[\]=filed"[^>]*aria-current="true"})
      expect(body).not_to include('month-chart__link--chosen')
      expect(body).to match(%r{ledger-total__title">2025</h2>.*25\.00 GBP}m)
    end
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
      filed('mid.pdf', on: nov + 9, cents: 5000, at: Time.now - 30)
      filed('late.pdf', on: nov + 20, cents: 2000, at: Time.now - 20)
      filed('december.pdf', on: Date.new(2025, 12, 3), cents: 4000, at: Time.now - 10)
      submission('reading.pdf', 'scanning', 'scanning.extracting')
    end

    it 'lists those dated in the range, leaving out ones with no date yet' do
      get '/expenses?from=2025-11-01&to=2025-11-30'

      expect(filenames(last_response.body)).to eq(%w[late.pdf mid.pdf early.pdf])
      expect(last_response.body).to include('href="/expenses" aria-label="November 2025: 80.00 GBP, 3 expenses" aria-current="true"')
    end

    it 'takes a range open at either end' do
      get '/expenses?from=2025-11-15'
      expect(filenames(last_response.body)).to eq(%w[december.pdf late.pdf])

      get '/expenses?to=2025-11-15'
      expect(filenames(last_response.body)).to eq(%w[mid.pdf early.pdf])
      # Not a whole month: none is chosen, but the dates can still be cleared.
      expect(last_response.body).to include('>All dates<')
      expect(last_response.body).not_to include('month-chart__link--chosen')
    end

    it 'takes emptied date fields as no dates' do
      get '/expenses?from=&to=&state[]=filed'

      expect(last_response.status).to eq(200)
      expect(filenames(last_response.body)).to eq(%w[december.pdf late.pdf mid.pdf early.pdf])
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

      expect(last_response.body).to match(%r{value="filed"[^>]*>.*?filter__count">3<}m)
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
