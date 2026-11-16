# frozen_string_literal: true

module UI
  # Amounts as a person reads them.
  module Money
    # +cents+ in +currency+, with thousands separated: "1,234.56 USD".
    def self.format(cents, currency)
      units, rest = cents.abs.divmod(100)
      "#{'-' if cents.negative?}#{units.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}.#{rest.to_s.rjust(2, '0')} #{currency}"
    end
  end
end
