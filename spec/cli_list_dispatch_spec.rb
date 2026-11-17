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
      db[:submissions].delete
      example.run
    end
  end

  def row(description, machine, on: Date.new(2026, 3, 1), **columns)
    SecureRandom.hex(16).tap do |expense_id|
      db[:submissions].insert(expense_id:, filename: "#{description}.pdf", machine: JSON.generate(machine), description:,
                              incurred_on: on, total_cents: 1000, currency: 'GBP', uploaded_at: Time.now, updated_at: Time.now,
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

  let!(:suggested) { row('uber', %w[filed filed.vat_inferred], category: 'travel') }
  let!(:needs_vat) { row('hotel', %w[filed filed.vat_needs_review], category: 'accommodation_and_meals', on: Date.new(2026, 1, 5)) }
  let!(:chosen) { row('github', %w[filed filed.vat_confirmed], category: 'software', category_chosen: true) }
  let!(:none) { row('misc', %w[filed filed.vat_inferred]) }
  let!(:reviewing) { row('taxi', %w[reviewing], category: 'travel') }

  describe 'list' do
    it 'prints every field as JSON lines, with the state as --state takes it' do
      expect(json_lines.find { it[:expense_id] == needs_vat }).to eq(
        expense_id: needs_vat, state: 'vat_needs_review', filename: 'hotel.pdf', description: 'hotel', total_cents: 1000,
        currency: 'GBP', incurred_on: '2026-01-05', category: 'accommodation_and_meals', category_chosen: false
      )
    end

    it 'filters by state, category, whose category it is, and date' do
      ids = ->(*args) { json_lines(*args).map { it[:expense_id] }.sort }

      expect(ids.('--state', 'filed,vat_needs_review', '--category-status', 'suggested')).to eq([suggested, needs_vat].sort)
      expect(ids.('--category', 'travel')).to eq([suggested, reviewing].sort)
      expect(ids.('--category-status', 'chosen')).to eq([chosen])
      expect(ids.('--category-status', 'none')).to eq([none])
      expect(ids.('--from', '2026-02-01', '--state', 'vat_needs_review')).to eq([])
    end

    it 'prints a table to read' do
      expect(list('--category-status', 'chosen')).to include(chosen, 'filed', '10.00 GBP', 'Software and web services', 'github', '1 expense')
    end

    it 'refuses filters it does not know' do
      expect { list('--state', 'lost') }.to raise_error(Sidereal::CLI::Error, 'No such state: lost')
      expect { list('--category', 'snacks') }.to raise_error(Sidereal::CLI::Error, 'No such category: snacks')
      expect { list('--category-status', 'maybe') }.to raise_error(Sidereal::CLI::Error, /suggested, chosen, none/)
    end
  end

  describe 'dispatch' do
    it 'sends a command for each listed expense, its payload from the line' do
      lines = list('--state', 'filed,vat_needs_review', '--category-status', 'suggested', '--json')

      expect(dispatch(lines, 'expenses.choose_category')).to include('2 commands')
      expect(choices.slice(suggested, needs_vat, chosen, none, reviewing))
        .to eq(suggested => 'travel', needs_vat => 'accommodation_and_meals')
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
