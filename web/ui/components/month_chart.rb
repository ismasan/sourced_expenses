# frozen_string_literal: true

module UI
  module Components
    # Filed expenses in the reporting currency (Expenses::Ledger.months),
    # and the list's date filter. One year is expanded: a bar a month, with
    # what the month comes to on top and the year's band under its months.
    # Every other year is one column, its total in a single bar. The year
    # expanded is the one the list's dates are in (a year chosen, or a month
    # of it), else the latest.
    #
    # A month or a year is a link to the list filtered to it (?from=…&to=…,
    # keeping the states chosen), so a year's column expands it; the one
    # chosen is highlighted, and its link goes back to all dates.
    #
    # One scale for years: a year's grey bar is as tall as its share of the
    # biggest year, and the year expanded has a thin line across it that
    # high, its black months scaled under it (its biggest month and its
    # figure reaching it), so where a year stands among the others shows,
    # expanded or not. Every bar has its figure on top. Colour in this app means whose
    # move it is, so the chart keeps to black and greys. Months and years
    # are lists of links, so a screen reader reads every total as text.
    #
    # It scrolls sideways when the columns don't fit, starting at what's
    # chosen, or the year expanded.
    class MonthChart < Phlex::HTML
      # Shows what's chosen, else the year expanded (its start, if wider
      # than the strip), once the chart is on the page.
      SCROLL = <<~JS.tr("\n", ' ').freeze
        const shown = el.querySelector('[aria-current]') || el.querySelector('[data-expanded]');
        if (shown) { el.scrollLeft = Math.min(shown.offsetLeft, shown.offsetLeft - (el.clientWidth - shown.offsetWidth) / 2) }
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
      # @param categories [Array<String>] its categories, kept too
      def initialize(months, from: nil, to: nil, states: [], categories: [])
        @years = months.group_by { it.from.year }.map { |year, of_year| Year.new(year:, months: of_year) }
        @from = from
        @to = to
        @states = states
        @categories = categories
        @expanded = (from || to)&.year || @years.last&.year
        @max_year = @years.map(&:cents).max.to_i
      end

      def view_template
        section(class: 'month-chart', aria: { labelledby: 'month-chart-title' }) do
          div(class: 'month-chart__head') do
            h2(id: 'month-chart-title', class: 'month-chart__title') { "Filed per month, in #{@years.first&.currency}" }
            a(class: 'month-chart__all', href: path) { 'All dates' } if @from || @to
          end
          ol(class: 'month-chart__years', data: { init: SCROLL }) do
            @years.each { it.year == @expanded ? render_expanded(it) : render_compact(it) }
          end
        end
      end

      private

      # The year's months, then its band: as wide as they are. A line runs
      # across the months as high as the year's bar would be (+--level+);
      # each month is a share of its biggest, and the CSS fits them under it.
      def render_expanded(year)
        level = share(year.cents, @max_year)
        max_month = year.months.map(&:cents).max.to_i
        li(class: 'month-chart__year', style: "--months: #{year.months.size}; --level: #{level}", data: { expanded: true }) do
          ol(class: 'month-chart__months') do
            year.months.each { render_month(it, share(it.cents, max_month)) }
          end
          chosen = chosen?(year)
          a(class: ['month-chart__band', ('month-chart__band--chosen' if chosen)], href: link(year, chosen),
            aria: { label: describe(year, year.year.to_s), current: (chosen ? 'true' : nil) }) do
            span(class: 'month-chart__band-label', aria: { hidden: 'true' }) { year.year.to_s }
          end
        end
      end

      # The whole year as one column, which expands it.
      def render_compact(year)
        li(class: 'month-chart__year month-chart__year--compact') do
          a(class: 'month-chart__link month-chart__link--year', href: path(from: year.from, to: year.to),
            aria: { label: describe(year, year.year.to_s) }) do
            render_plot(year.cents, year.cents.positive? ? share(year.cents, @max_year) : 0)
            # Where the months' names are, so the year lines up with the bands.
            span(class: 'month-chart__label', aria: { hidden: 'true' })
            span(class: 'month-chart__band', aria: { hidden: 'true' }) do
              span(class: 'month-chart__band-label') { year.year.to_s }
            end
            span(class: 'month-chart__tip', aria: { hidden: 'true' }) { describe(year, year.year.to_s) }
          end
        end
      end

      # +height+ is the bar's, as a share of the year's biggest month.
      def render_month(month, height)
        chosen = chosen?(month)
        li(class: 'month-chart__month') do
          a(class: ['month-chart__link', ('month-chart__link--chosen' if chosen)], href: link(month, chosen),
            aria: { label: describe(month, month.from.strftime('%B %Y')), current: (chosen ? 'true' : nil) }) do
            render_plot(month.cents, height)
            span(class: 'month-chart__label', aria: { hidden: 'true' }) { month.from.strftime('%b') }
            span(class: 'month-chart__tip', aria: { hidden: 'true' }) { describe(month, month.from.strftime('%B %Y')) }
          end
        end
      end

      # A bar +share+ of the plot's height tall, +cents+ on top; nothing for none.
      def render_plot(cents, share)
        span(class: 'month-chart__plot', aria: { hidden: 'true' }) do
          if cents.positive?
            span(class: 'month-chart__value') { Money.compact(cents) }
            span(class: 'month-chart__bar', style: "--share: #{share}")
          end
        end
      end

      # Whether the list's dates are exactly +period+'s.
      def chosen?(period) = @from == period.from && @to == period.to

      # The list filtered to +period+; back to all dates if it's the one chosen.
      def link(period, chosen) = chosen ? path : path(from: period.from, to: period.to)

      def path(**dates) = ExpensesPage.path_for(states: @states, categories: @categories, **dates)

      def share(cents, max) = max.zero? ? 0 : (cents.to_f / max).round(4)

      def describe(period, name)
        text = "#{name}: #{Money.format(period.cents, period.currency)}, " \
               "#{period.expenses == 1 ? '1 expense' : "#{period.expenses} expenses"}"
        text += ", #{period.unconverted} not in #{period.currency} yet" if period.unconverted.positive?
        text
      end
    end
  end
end
