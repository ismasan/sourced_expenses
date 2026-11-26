# frozen_string_literal: true

require 'sourced/testing/rspec'

module Expenses
  RSpec.describe CategoryList do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:expense_id) { SecureRandom.uuid }

    # Each example's categories are its own.
    around do |example|
      db.transaction(rollback: :always, auto_savepoint: true) do
        CategoryList.on_reset
        example.run
      end
      CategoryList.on_reset
    end

    def cmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })

    # +commands+ decided by the Expense, and projected here.
    def project(*commands, id: expense_id)
      history = decided(Expense, { expense_id: id }, *commands.map { it.class.new(payload: { **it.payload.to_h, expense_id: id }) })
      history.reduce(with_reactor(CategoryList, expense_id: id)) { |r, m| r.given(m) }.then! { nil }
    end

    def import(category:, source_category:)
      cmd(Expense::ImportExpense, source: 'freeagent', external_id: '1', filing_country: 'GB', description: 'Home office',
                                  net_price_cents: 2600, tax_amount_cents: 0, currency: 'GBP', incurred_on: Date.new(2026, 11, 1),
                                  category:, source_category:, vat_treatment: 'no_vat')
    end

    def entered = cmd(Expense::EnterExpense, filing_country: 'GB', description: 'Lunch', net_price_cents: 1000,
                                             currency: 'GBP', incurred_on: Date.new(2026, 11, 1))

    it 'lists a source’s own category with its name there, after the baseline' do
      project(import(category: 'materials', source_category: 'Materials'))

      choices = CategoryList.all(db)
      expect(choices.first(CATEGORIES.size).map(&:key)).to eq(CATEGORIES.keys)
      expect(choices.last).to eq(CategoryList::Choice.new(key: 'materials', label: 'Materials', description: nil))
      expect(db[:categories].where(key: 'materials').first).to include(label: 'Materials', source: 'freeagent')
      expect(Expenses.category_label('materials')).to eq('Materials')
    end

    it 'lists every category an expense has had: suggested, chosen, or imported' do
      project(entered, cmd(Expense::SuggestCategory, category: 'snacks', probability: 0.6, description: 'Lunch'))
      project(entered, cmd(Expense::ChooseCategory, category: 'team_lunches'), id: SecureRandom.uuid)

      expect(CategoryList.all(db).map(&:key)).to include('snacks', 'team_lunches')
      # No name to go on: its key, readable.
      expect(Expenses.category_label('team_lunches')).to eq('Team lunches')
    end

    it 'keeps the first name a category came with, taking one only if it had none' do
      project(entered, cmd(Expense::ChooseCategory, category: 'materials'))
      project(import(category: 'materials', source_category: 'Materials'), id: SecureRandom.uuid)
      project(import(category: 'materials', source_category: 'MATERIALS'), id: SecureRandom.uuid)

      expect(db[:categories].where(key: 'materials').select_map(:label)).to eq(['Materials'])
    end

    it 'lists the rest by name, and the baseline’s once, whatever expenses had them' do
      project(import(category: 'zoo_tickets', source_category: 'Zoo tickets'))
      project(import(category: 'cycle_to_work', source_category: 'Cycle to work'), id: SecureRandom.uuid)
      project(entered, cmd(Expense::ChooseCategory, category: 'travel'), id: SecureRandom.uuid)

      keys = CategoryList.all(db).map(&:key)
      expect(keys.drop(CATEGORIES.size)).to eq(%w[cycle_to_work zoo_tickets])
      expect(keys.count('travel')).to eq(1)
    end
  end
end
