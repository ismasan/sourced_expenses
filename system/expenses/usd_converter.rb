# frozen_string_literal: true

module Expenses
  # When an expense is filed (the first time, or again after a correction),
  # converts its total to US dollars at the rate on its date, and reports
  # back with Expense::RecordUSDAmount, or Expense::FailUSDConversion with
  # a reason a person can read. An expense in USD has nothing to convert.
  #
  # A consumer group of its own, so a slow rates service never holds up the
  # machine. Started on an existing store, it catches up on every filed
  # expense: the backfill is free. What it can expect to go wrong (no rate,
  # the service down: ExchangeRates::Error) becomes the failure; anything
  # else is a bug and raises, which stops its group.
  class USDConverter < Sourced::Decider
    partition_by expense_id: Types::UUID::V4

    dep :exchange_rates

    USD = 'USD'

    # Not the whole Document: the USD amount recorded for the total as
    # filed, if any. Filing again keeps it for the same total.
    context { { usd: nil } }

    evolve Expense::ExpenseFiled do |state, filed|
      state[:usd] = nil unless state[:usd] == USDConverter.amount(filed)
    end

    evolve Expense::USDAmountRecorded do |state, recorded|
      state[:usd] = recorded.payload.to_h.slice(:currency, :amount_cents, :incurred_on)
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

    reaction Expense::ExpenseFiled => Expense::RecordUSDAmount | Expense::FailUSDConversion | nil do |state, filed|
      next if filed.payload.currency == USD
      # Corrected, voided or converted since (a new consumer group catching
      # up): no call to make. The machine checks again, since the expense
      # may move on while the rate is fetched.
      next unless projection.current?(filed)

      amount = self.class.amount(filed)
      # Filed again with the same total, already converted.
      next if state[:usd] == amount

      expense_id = filed.payload.expense_id
      begin
        rate = exchange_rates.rate(from: amount[:currency], to: USD, on: amount[:incurred_on])
        dispatch(Expense::RecordUSDAmount, expense_id:, **amount,
                                           usd_cents: rate.convert(amount[:amount_cents]), rate: rate.rate, rate_date: rate.date)
      rescue ExchangeRates::Error => e
        dispatch(Expense::FailUSDConversion, expense_id:, **amount, reason: e.message)
      end
    end
  end
end
