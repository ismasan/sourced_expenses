# frozen_string_literal: true

module Expenses
  # The read model for totals in the reporting currency: one row per filed
  # expense, in the `ledger` table, with its total converted once
  # Expenses::CurrencyConverter has recorded it (and to which currency). A
  # correction to the amount, currency or date clears the conversion until
  # the new one is recorded; a voided expense leaves the ledger.
  #
  # Rows don't know the reporting currency: totals are asked for in one. An
  # expense in it counts as it is, one converted to it counts converted, and
  # any other isn't in the total yet. So changing the reporting currency
  # needs no rebuild here, only conversions to the new one.
  #
  #   Ledger.month(db, 'GBP')                      # this month
  #   Ledger.month(db, 'GBP', Date.new(2025, 10))  # October 2025
  #   Ledger.total(db, 'GBP', from:, to:)          # any range
  class Ledger < Sourced::Projector::StateStored
    partition_by expense_id: Types::UUID::V4

    dep :db

    # Filed expenses dated +from+ to +to+ (nil for no bound): how many, what
    # they come to in +currency+, and how many aren't in that total yet,
    # waiting for (or failing) conversion.
    Total = ::Data.define(:currency, :from, :to, :cents, :expenses, :unconverted) do
      # Whether it's one whole month.
      def month? = !from.nil? && !to.nil? && from.day == 1 && to == from.next_month - 1
    end

    # The month +date+ is in, by the expenses' own dates.
    # @return [Total]
    def self.month(db, currency, date = Date.today)
      from = Date.new(date.year, date.month, 1)
      total(db, currency, from:, to: from.next_month - 1)
    end

    # Filed expenses dated +from+ to +to+, by their own dates, in +currency+.
    # @return [Total]
    def self.total(db, currency, from: nil, to: nil)
      rows = db[:ledger]
      rows = rows.where { incurred_on >= from } if from
      rows = rows.where { incurred_on <= to } if to
      cents = Sequel.case([[{ currency: }, :amount_cents], [{ reporting_currency: currency }, :reporting_cents]], nil)
      # Not converted yet is NULL: coalesced, or excluding would skip it.
      counted = Sequel.|({ currency: }, { Sequel.function(:coalesce, :reporting_currency, '') => currency })
      Total.new(currency:, from:, to:, cents: rows.sum(cents).to_i, expenses: rows.count,
                unconverted: rows.exclude(counted).count)
    end

    COLUMNS = %i[description incurred_on currency amount_cents reporting_currency reporting_cents updated_at].freeze

    context { {} }

    load_context do |partition|
      db[:ledger].where(expense_id: partition[:expense_id]).first
    end

    # Filed, or filed again after a correction. The conversion stays if the
    # total it's for does.
    evolve Expense::ExpenseFiled do |row, evt|
      p = evt.payload
      filed = { currency: p.currency, amount_cents: p.net_price_cents + p.tax_amount_cents, incurred_on: p.incurred_on }
      row.merge!(reporting_currency: nil, reporting_cents: nil) unless row.slice(*filed.keys) == filed
      row.merge!(filed, expense_id: p.expense_id, description: p.description, voided: false, updated_at: evt.created_at)
    end

    # For the total as filed now: one for an amount since corrected is
    # dropped, as the machine drops it.
    evolve Expense::ConversionRecorded do |row, evt|
      p = evt.payload
      next unless row.slice(:currency, :amount_cents, :incurred_on) == { currency: p.currency, amount_cents: p.amount_cents, incurred_on: p.incurred_on }

      row.merge!(reporting_currency: p.reporting_currency, reporting_cents: p.reporting_cents, updated_at: evt.created_at)
    end

    evolve Expense::ExpenseVoided do |row, _evt|
      row[:voided] = true
    end

    sync do |context:, **|
      next unless context[:expense_id]

      rows = db[:ledger]
      if context[:voided]
        rows.where(expense_id: context[:expense_id]).delete
      else
        row = context.slice(*COLUMNS)
        rows.insert_conflict(target: :expense_id, update: row).insert(row.merge(expense_id: context[:expense_id]))
      end
    end
  end
end
