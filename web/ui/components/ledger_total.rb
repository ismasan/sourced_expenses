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
      # @param categories [Array<String>] the categories it's of, named in
      #   the title; none for every expense
      # @param search [String, nil] what the expenses were searched for, named too
      def initialize(total, categories: [], search: nil)
        @total = total
        @search = search
        # In the list's order, however they came.
        @categories = Expenses::CATEGORIES.keys & categories
      end

      def view_template
        section(id: 'ledger-total', class: 'ledger-total', aria: { labelledby: 'ledger-total-title' }) do
          h2(id: 'ledger-total-title', class: 'ledger-total__title') do
            if (of = categories_title)
              span(class: 'ledger-total__categories', title: @categories.map { Expenses.category_label(it) }.join(', ')) { of }
              plain ' · '
            end
            if @search
              span(class: 'ledger-total__search') { "“#{@search}”" }
              plain ' · '
            end
            plain title
          end
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
        return from.year.to_s if @total.year?
        return "#{day(from)} – #{day(to)}" if from && to
        return "Since #{day(from)}" if from
        return "Until #{day(to)}" if to

        'All time'
      end

      # One category by name; several by how many, all of them in its tooltip.
      def categories_title
        return if @categories.empty?

        @categories.one? ? Expenses.category_label(@categories.first) : "#{@categories.size} categories"
      end

      def day(date) = date.strftime('%-d %b %Y')
    end
  end
end
