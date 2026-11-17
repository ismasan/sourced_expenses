# frozen_string_literal: true

module UI
  # Amounts as a person reads them.
  module Money
    # +cents+ in +currency+, with thousands separated: "1,234.56 USD".
    def self.format(cents, currency)
      units, rest = cents.abs.divmod(100)
      "#{'-' if cents.negative?}#{units.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}.#{rest.to_s.rjust(2, '0')} #{currency}"
    end

    # +cents+ as a short figure, for a chart: whole units with thousands
    # separated under 10,000 ("158", "2,450"), thousands above ("12.3K").
    def self.compact(cents)
      units = (cents / 100.0).round
      return "#{(units / 1000.0).round(1).to_s.delete_suffix('.0')}K" if units.abs >= 10_000

      units.to_s.reverse.scan(/\d{1,3}/).join(',').reverse.then { units.negative? ? "-#{it}" : it }
    end
  end
end
