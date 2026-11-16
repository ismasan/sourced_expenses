# frozen_string_literal: true

# The currency expenses are totalled in: each filed expense's total is
# converted to it (Expenses::CurrencyConverter), and the ledger's totals are
# in it (Expenses::Ledger). An ISO code, GBP unless REPORTING_CURRENCY says
# otherwise.
#
#   REPORTING_CURRENCY=EUR bin/dev
#
# Changing it on a store with expenses converted already: reset the
# converter's consumer group (`bin/sid sourced groups reset
# expenses.currency_converter`) to convert them all again. Until then, they
# count as not converted.
Sidereal.config.tap do |c|
  c.declare('reporting_currency', Sidereal::Types::String[/\A[A-Z]{3}\z/]) do
    ENV.fetch('REPORTING_CURRENCY', 'GBP')
  end
end
