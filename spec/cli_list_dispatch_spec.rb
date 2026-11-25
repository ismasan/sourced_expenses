# frozen_string_literal: true

require 'sidereal/cli'
require_relative '../cli/expenses'

RSpec.describe 'bin/sid expenses list | dispatch' do
  let(:store) { Sidereal.config['sourced.store'] }
  let(:db) { Sidereal.config['db'] }
  let(:out) { StringIO.new }

  # The app is built already, by spec_helper.
  before { allow(Sidereal::CLI).to receive(:boot_app!) }

  around do |example|
    db.transaction(rollback: :always, auto_savepoint: true) do
      db[:expenses].delete
      db[:expenses_search].delete
      example.run
    end
  end

  def row(description, machine, on: Date.new(2026, 3, 1), **columns)
    SecureRandom.hex(16).tap do |expense_id|
      db[:expenses].insert(expense_id:, document_id: nil, machine: JSON.generate(machine), description:, vendor: "#{description} ltd",
                           incurred_on: on, total_cents: 1000, currency: 'GBP', created_at: Time.now, updated_at: Time.now,
                           **columns)
    end
  end

  def list(*arguments)
    StringIO.new.tap { CLI::Expenses::List.new(arguments, output: it).call }.string
  end

  def json_lines(*arguments) = list(*arguments, '--json').lines.map { JSON.parse(it, symbolize_names: true) }

  def dispatch(input, *arguments)
    CLI::Expenses::Dispatch.new(arguments, output: out, input: StringIO.new(input)).call
    out.string
  end

  def choices
    store.read_all(limit: 10_000).to_a.select { it.is_a?(Expenses::Expense::ChooseCategory) }
         .to_h { [it.payload.expense_id, it.payload.category] }
  end

  let!(:suggested) { row('uber', %w[reviewing reviewing.vat.vat_confirmed], category: 'travel', vat_treatment: 'domestic', vat_confirmed: true) }
  let!(:hotel) do
    row('hotel', %w[reviewing], category: 'accommodation_and_meals', vat_treatment: 'foreign_vat', filing_country: 'NL',
                                on: Date.new(2026, 1, 5))
  end
  let!(:chosen) { row('github', %w[filed], category: 'software', category_chosen: true, vat_treatment: 'import', vat_confirmed: true) }
  let!(:none) { row('misc', %w[reviewing]) }
  let!(:ready) { row('taxi', %w[reviewed], category: 'travel', category_chosen: true, vat_treatment: 'domestic', vat_confirmed: true) }

  describe 'list' do
    it 'prints every field as JSON lines, with the state as --state takes it' do
      expect(json_lines.find { it[:expense_id] == hotel }).to eq(
        expense_id: hotel, state: 'reviewing', document_id: nil, description: 'hotel', vendor: 'hotel ltd', total_cents: 1000,
        currency: 'GBP', incurred_on: '2026-01-05', category: 'accommodation_and_meals', category_chosen: false,
        vat_treatment: 'foreign_vat', vat_confirmed: false, filing_country: 'NL'
      )
    end

    it 'filters by state, category, whose category it is, and date' do
      ids = ->(*args) { json_lines(*args).map { it[:expense_id] }.sort }

      expect(ids.('--state', 'reviewing,filed', '--category-status', 'suggested')).to eq([suggested, hotel].sort)
      expect(ids.('--category', 'travel')).to eq([suggested, ready].sort)
      expect(ids.('--category-status', 'chosen')).to eq([chosen, ready].sort)
      expect(ids.('--category-status', 'none')).to eq([none])
      expect(ids.('--from', '2026-02-01', '--category', 'accommodation_and_meals')).to eq([])
    end

    it 'filters by the country it is filed in, any of several' do
      db[:expenses].where(expense_id: [suggested, chosen]).update(filing_country: 'GB')
      ids = ->(*args) { json_lines(*args).map { it[:expense_id] }.sort }

      expect(ids.('--filing-country', 'nl')).to eq([hotel])
      expect(ids.('--filing-country', 'GB,NL')).to eq([suggested, hotel, chosen].sort)
      expect(ids.('--filing-country', 'GB', '--state', 'filed')).to eq([chosen])
      expect { list('--filing-country', 'Netherlands') }.to raise_error(Sidereal::CLI::Error, /two-letter country codes, not NETHERLANDS/)
    end

    it 'filters by whose VAT treatment it is, any of several statuses' do
      ids = ->(*args) { json_lines(*args).map { it[:expense_id] }.sort }

      expect(ids.('--vat-status', 'suggested')).to eq([hotel])
      expect(ids.('--vat-status', 'confirmed', '--state', 'reviewing')).to eq([suggested])
      expect(ids.('--vat-status', 'suggested,none')).to eq([hotel, none].sort)
      expect(ids.('--vat-status', 'confirmed', '--category-status', 'suggested,none')).to eq([suggested])
      expect(list('--vat-status', 'suggested')).to include('foreign_vat (suggested)')
    end

    it 'filters by what the expenses say, as the search box does' do
      db[:expenses].each do |row|
        db[:expenses_search].insert(expense_id: row[:expense_id], body: Expenses::ExpenseList.search_body(row))
      end

      expect(json_lines('--search', 'UBE').map { it[:expense_id] }).to eq([suggested])
      expect(json_lines('--search', 'travel', '--state', 'reviewed').map { it[:expense_id] }).to eq([ready])
    end

    it 'prints a table to read' do
      expect(list('--state', 'filed')).to include(chosen, 'filed', '10.00 GBP', 'Software and web services', 'github', '1 expense')
    end

    it 'refuses filters it does not know' do
      expect { list('--state', 'lost') }.to raise_error(Sidereal::CLI::Error, 'No such state: lost')
      expect { list('--category', 'snacks') }.to raise_error(Sidereal::CLI::Error, 'No such category: snacks')
      expect { list('--category-status', 'maybe') }.to raise_error(Sidereal::CLI::Error, /suggested, chosen, none/)
      expect { list('--vat-status', 'maybe') }.to raise_error(Sidereal::CLI::Error, /suggested, confirmed, none/)
    end
  end

  describe 'dispatch' do
    it 'sends a command for each listed expense, its payload from the line' do
      lines = list('--state', 'reviewing', '--category-status', 'suggested', '--json')

      expect(dispatch(lines, 'expenses.choose_category')).to include('2 commands')
      expect(choices.slice(suggested, hotel, chosen, none, ready))
        .to eq(suggested => 'travel', hotel => 'accommodation_and_meals')
    end

    it 'takes attributes given to it over the lines’' do
      dispatch(%({"expense_id":"#{none}","category":null}\n), 'expenses.choose_category', '--category', 'office_costs')

      expect(choices[none]).to eq('office_costs')
    end

    it 'sends nothing on a dry run' do
      expect { dispatch(%({"expense_id":"#{none}","category":"travel"}), 'expenses.choose_category', '--dry-run') }
        .not_to(change { choices.size })
      expect(out.string).to include('Would dispatch expenses.choose_category', '1 command (dry run)')
    end

    it 'sends nothing if any line is invalid' do
      input = %({"expense_id":"#{suggested}","category":"travel"}\n{"expense_id":"#{none}","category":"snacks"}\n)

      expect { dispatch(input, 'expenses.choose_category') }
        .to raise_error(Sidereal::CLI::Error, /Nothing dispatched.*Line 2: --category: must be included/m)
      expect(choices).not_to include(suggested)
    end
  end
end
