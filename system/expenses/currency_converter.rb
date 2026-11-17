# frozen_string_literal: true

module Expenses
  # When an expense is filed (the first time, or again after a correction),
  # converts its total to the reporting currency (`reporting_currency`, GBP
  # by default) at the rate on its date, and reports back with
  # Expense::RecordConversion, or Expense::FailConversion with a reason a
  # person can read. An expense in the reporting currency has nothing to
  # convert.
  #
  # A consumer group of its own, so a slow rates service never holds up the
  # machine. Started on an existing store, it catches up on every filed
  # expense: the backfill is free. Reset after the reporting currency
  # changes, it converts again what was converted to another one. What it
  # can expect to go wrong (no rate, the service down: ExchangeRates::Error)
  # becomes the failure; anything else is a bug and raises, which stops its
  # group.
  class CurrencyConverter < Sourced::Decider
    partition_by expense_id: Types::ExpenseID

    dep :exchange_rates, :reporting_currency

    # Not the whole Document: the filed total, and the conversion recorded
    # for it, if any. Filing again keeps the conversion for the same total.
    context { { filed: nil, converted: nil } }

    evolve Expense::ExpenseFiled do |state, filed|
      state[:filed] = CurrencyConverter.amount(filed)
      state[:converted] = nil unless state[:converted]&.slice(:currency, :amount_cents, :incurred_on) == state[:filed]
    end

    evolve Expense::ConversionRecorded do |state, recorded|
      state[:converted] = recorded.payload.to_h.slice(:currency, :amount_cents, :incurred_on, :reporting_currency)
    end

    # Nothing to keep: evolved so voiding counts as moving on for
    # projection.current?. A failure doesn't, so a group catching up tries
    # those again.
    evolve(Expense::ExpenseVoided) { |_state, _evt| nil }

    # What's converted: the filed total, VAT included.
    def self.amount(filed)
      { currency: filed.payload.currency, amount_cents: filed.payload.net_price_cents + filed.payload.tax_amount_cents,
        incurred_on: filed.payload.incurred_on }
    end

    reaction Expense::ExpenseFiled => Expense::RecordConversion | Expense::FailConversion | nil do |state, filed|
      # Corrected, voided or converted since (a new consumer group catching
      # up): no call to make. The machine checks again, since the expense
      # may move on while the rate is fetched.
      next unless projection.current?(filed)

      convert(filed.payload.expense_id, state)
    end

    # The latest thing to happen to the expense is a conversion to another
    # currency than the reporting one: the group was reset after the
    # reporting currency changed. Converted again, to this one.
    reaction Expense::ConversionRecorded => Expense::RecordConversion | Expense::FailConversion | nil do |state, recorded|
      next if recorded.payload.reporting_currency == reporting_currency
      next unless projection.current?(recorded)

      convert(recorded.payload.expense_id, state)
    end

    private

    def convert(expense_id, state)
      amount = state[:filed]
      return if amount.nil? || amount[:currency] == reporting_currency
      # Already converted to this currency, for this total.
      return if state[:converted] == amount.merge(reporting_currency:)

      rate = exchange_rates.rate(from: amount[:currency], to: reporting_currency, on: amount[:incurred_on])
      dispatch(Expense::RecordConversion, expense_id:, **amount, reporting_currency:,
                                          reporting_cents: rate.convert(amount[:amount_cents]), rate: rate.rate, rate_date: rate.date)
    rescue ExchangeRates::Error => e
      dispatch(Expense::FailConversion, expense_id:, **amount, reporting_currency:, reason: e.message)
    end
  end
end
