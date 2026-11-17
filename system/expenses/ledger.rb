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
    partition_by expense_id: Types::ExpenseID

    dep :db

    # Filed expenses dated +from+ to +to+ (nil for no bound): how many, what
    # they come to in +currency+, and how many aren't in that total yet,
    # waiting for (or failing) conversion.
    Total = ::Data.define(:currency, :from, :to, :cents, :expenses, :unconverted) do
      # Whether it's one whole month.
      def month? = !from.nil? && !to.nil? && from.day == 1 && to == from.next_month - 1

      # Whether it's one whole calendar year.
      def year? = !from.nil? && from == Date.new(from.year, 1, 1) && to == Date.new(from.year, 12, 31)
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
      Total.new(currency:, from:, to:, cents: rows.sum(cents_in(currency)).to_i, expenses: rows.count,
                unconverted: rows.exclude(counted_in(currency)).count)
    end

    # Every month from the first one an expense is dated in to the one
    # +date+ is in (or the last one dated in, if later), oldest first, a
    # Total each: months with nothing filed in between are there too, empty.
    # Just +date+'s month when nothing is filed.
    # @return [Array<Total>]
    def self.months(db, currency, date: Date.today)
      dates = db[:ledger].select(Sequel.function(:min, :incurred_on).as(:earliest),
                                 Sequel.function(:max, :incurred_on).as(:latest)).first
      earliest, latest = dates.values_at(:earliest, :latest).map { Types.iso_date(it&.to_s) }
      last = month_of([latest, date].compact.max)
      first = earliest ? month_of(earliest) : last
      firsts = []
      (firsts << first; first >>= 1) while first <= last
      month = Sequel.function(:strftime, '%Y-%m-01', :incurred_on)
      rows = db[:ledger].where { incurred_on >= firsts.first }.where { incurred_on < last.next_month }
                        .group(month)
                        .select(month.as(:month), Sequel.function(:sum, cents_in(currency)).as(:cents),
                                Sequel.function(:count, Sequel.lit('*')).as(:expenses),
                                Sequel.function(:sum, Sequel.case([[counted_in(currency), 0]], 1)).as(:unconverted))
                        .to_h { [Types.iso_date(it[:month]), it] }
      firsts.map do |first|
        row = rows.fetch(first, {})
        Total.new(currency:, from: first, to: first.next_month - 1, cents: row[:cents].to_i, expenses: row[:expenses].to_i,
                  unconverted: row[:unconverted].to_i)
      end
    end

    def self.month_of(date) = Date.new(date.year, date.month, 1)

    # A row's total in +currency+: as it is if in it, converted if
    # converted to it, else NULL (which sums skip).
    def self.cents_in(currency)
      Sequel.case([[{ currency: }, :amount_cents], [{ reporting_currency: currency }, :reporting_cents]], nil)
    end

    # Whether a row counts in +currency+'s total. Not converted yet is NULL:
    # coalesced, or excluding would skip it.
    def self.counted_in(currency)
      Sequel.|({ currency: }, { Sequel.function(:coalesce, :reporting_currency, '') => currency })
    end
    private_class_method :month_of, :cents_in, :counted_in

    COLUMNS = %i[description incurred_on currency amount_cents reporting_currency reporting_cents updated_at].freeze

    # The group's offsets were rewound (`bin/sid sourced groups reset
    # expenses.ledger`): every row goes, and it builds them again from the
    # start of the store once started.
    def self.on_reset = Sidereal.config['db'][:ledger].delete

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
