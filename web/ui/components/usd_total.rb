# frozen_string_literal: true

module UI
  module Components
    # Filed expenses in US dollars (Expenses::USDLedger::Total): the total,
    # and what it covers. This month's, or a range's. By its id, a page can
    # re-render just this when the ledger commits.
    class USDTotal < Phlex::HTML
      # This month's, from the ledger.
      def self.current = new(Expenses::USDLedger.month(Sidereal.config['db']))

      # @param total [Expenses::USDLedger::Total]
      def initialize(total)
        @total = total
      end

      def view_template
        section(id: 'usd-total', class: 'usd-total', aria: { labelledby: 'usd-total-title' }) do
          h2(id: 'usd-total-title', class: 'usd-total__title') { title }
          p(class: 'usd-total__amount') { Money.format(@total.usd_cents, 'USD') }
          p(class: 'usd-total__note') do
            plain(@total.expenses == 1 ? '1 expense filed' : "#{@total.expenses} expenses filed")
            plain ", #{@total.unconverted} not in US dollars yet" if @total.unconverted.positive?
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
