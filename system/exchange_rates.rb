# frozen_string_literal: true

require 'bigdecimal'

# Currency exchange rates, behind an interface so the source can change:
# ExchangeRates::Frankfurter (ECB reference rates) by default. The
# `exchange_rates` component (config/components/exchange_rates.rb) is one.
#
#   rates.rate(from: 'EUR', to: 'USD', on: Date.new(2025, 10, 24))
#   # => #<data ExchangeRates::Rate rate=1.1612, date=#<Date: 2025-10-24>>
module ExchangeRates
  # +rate+ is how many +to+ one +from+ buys, on +date+: the day the rate is
  # for, which may be earlier than the day asked for (no rates at weekends).
  Rate = Data.define(:rate, :date) do
    # +cents+ of the +from+ currency in cents of +to+, to the nearest cent.
    def convert(cents) = (BigDecimal(cents) * BigDecimal(rate.to_s)).round(0, :half_even).to_i
  end

  # Anything that stops a rate being found, with a message a person can read.
  Error = Class.new(StandardError)
end
