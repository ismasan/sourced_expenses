# frozen_string_literal: true

require 'rack/test'

RSpec.describe UI::Components::NewExpenseForm do
  include Rack::Test::Methods

  def app = App

  let(:store) { Sidereal.config['sourced.store'] }
  let(:expense_id) { SecureRandom.uuid }

  def entered = store.read_all(limit: 10_000).to_a.select { it.is_a?(Expenses::Expense::EnterExpense) }

  def enter(**payload)
    post '/commands', {
      command: { type: 'web.new_expense', _cid: 'web_new_expense-cmd', payload: {
        expense_id:, description: 'Train to Leeds', net_price_cents: '4500', tax_amount_cents: '0', tax_description: '',
        currency: 'GBP', incurred_on: '2026-08-09', supplier_country_code: '', reverse_charge: '0', payment_reference: '',
        **payload
      } }
    }, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'
  end

  it 'is on its own page, with a fresh id each time it renders' do
    get '/expenses/new'
    body = last_response.body

    expect(last_response.status).to eq(200)
    expect(body).to include('New expense', 'web.new_expense', 'name="command[payload][description]"',
                            'name="command[payload][net_price_cents]"', 'Add expense')
    id = body[/name="command\[payload\]\[expense_id\]" value="([^"]+)"/, 1]
    expect(Types::ExpenseID === id).to be(true)

    get '/expenses/new'
    expect(last_response.body).not_to include(id)
  end

  it 'enters the expense, with the filing country, and goes to its page' do
    expect { enter }.to change { entered.size }.by(1)

    expect(entered.last.payload.to_h).to include(
      expense_id:, filing_country: 'NL', description: 'Train to Leeds', net_price_cents: 4500,
      tax_amount_cents: 0, currency: 'GBP', incurred_on: Date.new(2026, 8, 9), tax_description: nil
    )
    expect(last_response.body).to include("/expenses/#{expense_id}")
    expect(last_response.body).to match(/window\.location|redirect/)
  end

  it 'refuses a form missing what an expense needs, entering nothing' do
    expect { enter(description: '', currency: 'pounds') }.not_to(change { entered.size })

    expect(last_response.body).to include('web_new_expense-cmd-description-errors', 'web_new_expense-cmd-currency-errors')
  end
end
