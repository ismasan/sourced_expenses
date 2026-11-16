# frozen_string_literal: true

module UI
  module Components
    # Filed expenses in the reporting currency (Expenses::Ledger::Total): the
    # total, and what it covers. This month's, or a range's. By its id, a
    # page can re-render just this when the ledger commits.
    class LedgerTotal < Phlex::HTML
      # This month's, from the ledger.
      def self.current
        new(Expenses::Ledger.month(Sidereal.config['db'], Sidereal.config['reporting_currency']))
      end

      # @param total [Expenses::Ledger::Total]
      def initialize(total)
        @total = total
      end

      def view_template
        section(id: 'ledger-total', class: 'ledger-total', aria: { labelledby: 'ledger-total-title' }) do
          h2(id: 'ledger-total-title', class: 'ledger-total__title') { title }
          p(class: 'ledger-total__amount') { Money.format(@total.cents, @total.currency) }
          p(class: 'ledger-total__note') do
            plain(@total.expenses == 1 ? '1 expense filed' : "#{@total.expenses} expenses filed")
            plain ", #{@total.unconverted} not in #{@total.currency} yet" if @total.unconverted.positive?
          end
        end
      end

      private

      def title
        from, to = @total.from, @total.to
        return from.strftime('%B %Y') if @total.month?
        return "#{day(from)} – #{day(to)}" if from && to
        return "Since #{day(from)}" if from
        return "Until #{day(to)}" if to

        'All time'
      end

      def day(date) = date.strftime('%-d %b %Y')
    end
  end
end
