# frozen_string_literal: true

module Expenses
  # The read model for totals in US dollars: one row per filed expense, in
  # the `usd_ledger` table, with its total in USD once
  # Expenses::UsdConverter has recorded it. An expense in USD counts as it
  # is. A correction to the amount, currency or date clears the USD amount
  # until the new one is recorded; a voided expense leaves the ledger.
  #
  #   UsdLedger.month(db)                      # this month
  #   UsdLedger.month(db, Date.new(2025, 10))  # October 2025
  class UsdLedger < Sourced::Projector::StateStored
    partition_by expense_id: Types::UUID::V4

    dep :db

    USD = 'USD'

    # A month's filed expenses: how many, what they come to in USD, and
    # how many aren't in that total yet, waiting for (or failing) conversion.
    Month = ::Data.define(:first_day, :usd_cents, :expenses, :unconverted)

    # The month +date+ is in, by the expenses' own dates.
    # @return [Month]
    def self.month(db, date = Date.today)
      first_day = Date.new(date.year, date.month, 1)
      rows = db[:usd_ledger].where(incurred_on: first_day..(first_day.next_month - 1))
      Month.new(first_day:, usd_cents: rows.sum(:usd_cents).to_i, expenses: rows.count,
                unconverted: rows.where(usd_cents: nil).count)
    end

    COLUMNS = %i[description incurred_on currency amount_cents usd_cents updated_at].freeze

    context { {} }

    load_context do |partition|
      db[:usd_ledger].where(expense_id: partition[:expense_id]).first
    end

    # Filed, or filed again after a correction. The USD amount stays if the
    # total it's for does.
    evolve Expense::ExpenseFiled do |row, evt|
      p = evt.payload
      filed = { currency: p.currency, amount_cents: p.net_price_cents + p.tax_amount_cents, incurred_on: p.incurred_on }
      same = row.slice(*filed.keys) == filed
      row.merge!(filed, expense_id: p.expense_id, description: p.description, voided: false, updated_at: evt.created_at)
      if p.currency == USD
        row[:usd_cents] = filed[:amount_cents]
      elsif !same
        row[:usd_cents] = nil
      end
    end

    # For the total as filed now: one for an amount since corrected is
    # dropped, as the machine drops it.
    evolve Expense::UsdAmountRecorded do |row, evt|
      p = evt.payload
      next unless row.slice(:currency, :amount_cents, :incurred_on) == { currency: p.currency, amount_cents: p.amount_cents, incurred_on: p.incurred_on }

      row.merge!(usd_cents: p.usd_cents, updated_at: evt.created_at)
    end

    evolve Expense::ExpenseVoided do |row, _evt|
      row[:voided] = true
    end

    sync do |context:, **|
      next unless context[:expense_id]

      rows = db[:usd_ledger]
      if context[:voided]
        rows.where(expense_id: context[:expense_id]).delete
      else
        row = context.slice(*COLUMNS)
        rows.insert_conflict(target: :expense_id, update: row).insert(row.merge(expense_id: context[:expense_id]))
      end
    end
  end
end
