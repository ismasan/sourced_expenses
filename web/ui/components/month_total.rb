# frozen_string_literal: true

module UI
  module Components
    # A month's filed expenses in US dollars (Expenses::UsdLedger::Month):
    # the total, and what it covers. By its id, a page can re-render just
    # this when the ledger commits.
    class MonthTotal < Phlex::HTML
      # This month's, from the ledger.
      def self.current = new(Expenses::UsdLedger.month(Sidereal.config['db']))

      # @param month [Expenses::UsdLedger::Month]
      def initialize(month)
        @month = month
      end

      def view_template
        section(id: 'month-total', class: 'month-total', aria: { labelledby: 'month-total-title' }) do
          h2(id: 'month-total-title', class: 'month-total__title') { @month.first_day.strftime('%B %Y') }
          p(class: 'month-total__amount') { Money.format(@month.usd_cents, 'USD') }
          p(class: 'month-total__note') do
            plain(@month.expenses == 1 ? '1 expense filed' : "#{@month.expenses} expenses filed")
            plain ", #{@month.unconverted} not in US dollars yet" if @month.unconverted.positive?
          end
        end
      end
    end
  end
end
