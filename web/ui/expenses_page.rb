# frozen_string_literal: true

module UI
  # Every upload, newest first, a page at a time, with filters: by state
  # (UI::StateFilter) in a sidebar, and by the expense's date. Live: it
  # re-renders whenever the read model commits.
  #
  # The header has the total in the reporting currency of the filed
  # expenses in the dates chosen, whatever the states, or this month's
  # without dates. Under it, the chart of every month's total
  # (Components::MonthChart) is the date filter: a month's or a year's link
  # filters the list to it.
  #
  # The filters and the page number are in the query string
  # (?state[]=filed&from=2025-11-01&to=2025-11-30&page=2), typed by the
  # query schema: an unknown state, a page below 1 or a date that isn't
  # YYYY-MM-DD is a 400. A blank date is none. Any range works, though the
  # chart only makes whole months and years. The layout puts the params in the params
  # signal, so a live re-render keeps them.
  class ExpensesPage < Sidereal::Page
    path '/expenses'

    PER_PAGE = 25

    query_schema(
      state: StateFilter::Param,
      from?: Types::Date.nullable,
      to?: Types::Date.nullable,
      page: Types::Integer[1..].default(1)
    )

    on Expenses::Submissions::Projected, Expenses::Ledger::Projected

    def channel_name = 'expenses.>'

    # The list's URL for +states+, the dates +from+ and +to+, and +page+.
    def self.path_for(states: [], from: nil, to: nil, page: 1)
      query = states.map { "state[]=#{it}" }
      query << "from=#{from.iso8601}" if from
      query << "to=#{to.iso8601}" if to
      query << "page=#{page}" if page > 1
      query.empty? ? path : "#{path}?#{query.join('&')}"
    end

    def self.load(params, _ctx)
      db = Sidereal.config['db']
      filters = { states: params[:state], from: params[:from], to: params[:to] }
      page = params[:page]
      rows, total = Expenses::Submissions.page(db, **filters, page:, per_page: PER_PAGE)
      # Past the end (fewer rows since the link was made): the last page.
      if rows.empty? && page > 1
        page = [(total + PER_PAGE - 1) / PER_PAGE, 1].max
        rows, total = Expenses::Submissions.page(db, **filters, page:, per_page: PER_PAGE)
      end
      new(rows:, total:, **filters, page:, counts: Expenses::Submissions.counts(db, **filters.slice(:from, :to)),
          ledger_total: ledger_total(db, **filters),
          month_totals: Expenses::Ledger.months(db, Sidereal.config['reporting_currency']))
    end

    # The filed expenses in the dates chosen, or this month's.
    def self.ledger_total(db, from:, to:, **)
      currency = Sidereal.config['reporting_currency']
      from || to ? Expenses::Ledger.total(db, currency, from:, to:) : Expenses::Ledger.month(db, currency)
    end

    def initialize(rows:, total:, states:, from:, to:, page:, counts:, ledger_total:, month_totals:)
      @rows = rows
      @total = total
      @states = states
      @from = from
      @to = to
      @page = page
      @counts = counts
      @ledger_total = ledger_total
      @month_totals = month_totals
    end

    def view_template
      div(id: 'expenses-page', class: 'expenses-page') do
        header(class: 'expenses-page__header') do
          h1(class: 'expenses-page__title') { 'All expenses' }
          render Components::LedgerTotal.new(@ledger_total)
        end
        render Components::MonthChart.new(@month_totals, from: @from, to: @to, states: @states)

        # One plain GET form for every filter, the states in the sidebar and
        # the dates above the list: changing one reloads the list with them
        # all, from the first page.
        form(class: 'expenses-page__body', action: self.class.path, method: 'get', data: { 'on:change' => 'el.submit()' }) do
          render_filters
          # The dates are the chart's: kept here, so ticking a state keeps them.
          input(type: 'hidden', name: 'from', value: @from.iso8601) if @from
          input(type: 'hidden', name: 'to', value: @to.iso8601) if @to
          section(class: 'expenses-page__list', aria: { label: 'Expenses' }) do
            render_summary
            render Components::SubmissionList.new(@rows) if @rows.any?
            render_pager
          end
        end
      end
    end

    private

    def pages = [(@total + PER_PAGE - 1) / PER_PAGE, 1].max

    def filtered? = @states.any? || @from || @to

    # The states, each with its stage's colour and how many are in it (in
    # the dates chosen).
    def render_filters
      aside(class: 'filters', aria: { label: 'Filters' }) do
        fieldset(class: 'filters__group') do
          legend(class: 'filters__legend') { 'State' }
          StateFilter::OPTIONS.each do |option|
            label(class: "filter filter--#{option.stage}") do
              input(type: 'checkbox', name: 'state[]', value: option.key, checked: @states.include?(option.key))
              span(class: 'filter__label') { option.label }
              span(class: 'filter__count') { @counts.fetch(option.key, 0).to_s }
            end
          end
        end
        # Without JavaScript the change doesn't submit: this does.
        noscript { button(type: 'submit', class: 'button') { 'Apply' } }
        a(class: 'filters__clear', href: self.class.path) { 'Clear filters' } if filtered?
      end
    end


    def render_summary
      p(class: 'expenses-page__summary') do
        if @total.zero?
          plain(filtered? ? 'No expenses match the filters. ' : 'Nothing uploaded yet. ')
          a(href: filtered? ? self.class.path : '/') { filtered? ? 'Clear filters' : 'Upload a receipt' }
        else
          first = ((@page - 1) * PER_PAGE) + 1
          last = [first + @rows.size - 1, @total].min
          plain "#{first}–#{last} of #{@total}"
        end
      end
    end

    def render_pager
      return if pages == 1

      nav(class: 'pager', aria: { label: 'Pages' }) do
        pager_link('Newer', @page - 1, rel: 'prev')
        span(class: 'pager__where') { "Page #{@page} of #{pages}" }
        pager_link('Older', @page + 1, rel: 'next')
      end
    end

    def pager_link(text, page, rel:)
      if page.between?(1, pages)
        a(class: "pager__link pager__link--#{rel}", href: self.class.path_for(states: @states, from: @from, to: @to, page:), rel:) { text }
      else
        span(class: "pager__link pager__link--#{rel} pager__link--disabled", aria: { hidden: 'true' }) { text }
      end
    end
  end
end
