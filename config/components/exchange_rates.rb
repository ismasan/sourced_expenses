# frozen_string_literal: true

# Currency exchange rates (ExchangeRates): Frankfurter's, by default.
# Expenses::UsdConverter gets them with `dep :exchange_rates`; specs replace
# them with a fake.
#
#   EXCHANGE_RATES_URL=https://frankfurter.example.com/v1 bin/dev
Sidereal.config.tap do |c|
  c.declare('exchange_rates.url', Sidereal::Types::String) { ENV.fetch('EXCHANGE_RATES_URL', ExchangeRates::Frankfurter::DEFAULT_URL) }
  c.declare('exchange_rates', Sidereal::Types::Interface[:rate])
  c.config!('exchange_rates', ['exchange_rates.url']) { |url| ExchangeRates::Frankfurter.new(base_url: url) }
end
