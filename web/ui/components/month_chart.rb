# frozen_string_literal: true

module UI
  module Components
    # Filed expenses per month in the reporting currency
    # (Expenses::Ledger.months), and the list's date filter: a bar a month,
    # from the first one with an expense to this one, with what the month
    # comes to on top, and under the months each year's band, as wide as its
    # months. A month or a year is a link to the list filtered to it
    # (?from=…&to=…, keeping the states chosen); the one chosen is
    # highlighted, and its link goes back to all dates.
    #
    # It scrolls sideways when the months don't fit, starting at what's
    # chosen, or the latest month; a year's label stays in view while any of
    # its months are. Bars are black: colour in this app means whose move it
    # is. Months and years are lists of links, so a screen reader reads every
    # total as text; nothing is only in the drawing.
    class MonthChart < Phlex::HTML
      # Shows what's chosen (its start, if wider than the strip), else the
      # latest month, once the chart is on the page.
      SCROLL = <<~JS.tr("\n", ' ').freeze
        const chosen = el.querySelector('[aria-current]');
        if (chosen) { el.scrollLeft = Math.min(chosen.offsetLeft, chosen.offsetLeft - (el.clientWidth - chosen.offsetWidth) / 2) }
        else { el.scrollLeft = el.scrollWidth }
      JS

      Year = ::Data.define(:year, :months) do
        def from = Date.new(year, 1, 1)
        def to = Date.new(year, 12, 31)
        def cents = months.sum(&:cents)
        def expenses = months.sum(&:expenses)
        def unconverted = months.sum(&:unconverted)
        def currency = months.first.currency
      end

      # @param months [Array<Expenses::Ledger::Total>] whole months, oldest first
      # @param from [Date, nil] the list's dates: a whole month or year is the one chosen
      # @param to [Date, nil]
      # @param states [Array<String>] the states the list is filtered to, kept by the links
      def initialize(months, from: nil, to: nil, states: [])
        @years = months.group_by { it.from.year }.map { |year, of_year| Year.new(year:, months: of_year) }
        @from = from
        @to = to
        @states = states
        @max = months.map(&:cents).max.to_i
      end

      def view_template
        section(class: 'month-chart', aria: { labelledby: 'month-chart-title' }) do
          div(class: 'month-chart__head') do
            h2(id: 'month-chart-title', class: 'month-chart__title') { "Filed per month, in #{@years.first&.currency}" }
            a(class: 'month-chart__all', href: path) { 'All dates' } if @from || @to
          end
          ol(class: 'month-chart__years', data: { init: SCROLL }) do
            @years.each { render_year(it) }
          end
        end
      end

      private

      # The year's months, then its band: proportionally as wide as they are.
      def render_year(year)
        count = year.months.size
        li(class: 'month-chart__year', style: "--months: #{count}") do
          ol(class: 'month-chart__months') do
            year.months.each { render_month(it) }
          end
          chosen = chosen?(year)
          a(class: ['month-chart__band', ('month-chart__band--chosen' if chosen)], href: link(year, chosen),
            aria: { label: describe(year, year.year.to_s), current: (chosen ? 'true' : nil) }) do
            span(class: 'month-chart__band-label', aria: { hidden: 'true' }) { year.year.to_s }
          end
        end
      end

      def render_month(month)
        chosen = chosen?(month)
        li(class: 'month-chart__month') do
          a(class: ['month-chart__link', ('month-chart__link--chosen' if chosen)], href: link(month, chosen),
            aria: { label: describe(month, month.from.strftime('%B %Y')), current: (chosen ? 'true' : nil) }) do
            span(class: 'month-chart__plot', aria: { hidden: 'true' }) do
              if month.cents.positive?
                span(class: 'month-chart__value') { Money.compact(month.cents) }
                span(class: 'month-chart__bar', style: "--share: #{share(month)}")
              end
            end
            span(class: 'month-chart__label', aria: { hidden: 'true' }) { month.from.strftime('%b') }
            span(class: 'month-chart__tip', aria: { hidden: 'true' }) { describe(month, month.from.strftime('%B %Y')) }
          end
        end
      end

      # Whether the list's dates are exactly +period+'s.
      def chosen?(period) = @from == period.from && @to == period.to

      # The list filtered to +period+; back to all dates if it's the one chosen.
      def link(period, chosen) = chosen ? path : path(from: period.from, to: period.to)

      def path(**dates) = ExpensesPage.path_for(states: @states, **dates)

      # How tall the bar is, as a share of the tallest.
      def share(month) = @max.zero? ? 0 : (month.cents.to_f / @max).round(4)

      def describe(period, name)
        text = "#{name}: #{Money.format(period.cents, period.currency)}, " \
               "#{period.expenses == 1 ? '1 expense' : "#{period.expenses} expenses"}"
        text += ", #{period.unconverted} not in #{period.currency} yet" if period.unconverted.positive?
        text
      end
    end
  end
end
