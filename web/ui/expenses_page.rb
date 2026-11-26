# frozen_string_literal: true

module UI
  # Every expense, newest first, a page at a time, with filters: by state
  # (UI::StateFilter), category, and whose category and VAT treatment it
  # is (UI::ReviewFilter) in a sidebar, by the expense's date, and
  # by what it says (q, Expenses::ExpenseList.search: the top bar's search
  # box, UI::Components::Search, sends it here). Live: it re-renders
  # whenever the read model commits.
  #
  # The header has the total in the reporting currency of the filed
  # expenses in the dates, categories and search chosen, whatever the states, or
  # this month's without dates. Under it, the chart of every month's total
  # in those categories (Components::MonthChart) is the date filter: a
  # month's or a year's link filters the list to it.
  #
  # The filters and the page number are in the query string
  # (?state[]=filed&category[]=travel&category_status[]=chosen&vat_status[]=suggested&q=uber
  # &from=2025-11-01&to=2025-11-30&page=2), typed by the query schema: an unknown state,
  # category or status, a page below 1 or a date that isn't
  # YYYY-MM-DD is a 400. A blank date or search is none. Any range works, though the
  # chart only makes whole months and years. The layout puts the params in the params
  # signal, so a live re-render keeps them.
  class ExpensesPage < Page
    stylesheet 'ui/expenses_page.css', path: 'expenses_page.css'

    path '/expenses'

    PER_PAGE = 25

    # A category[] query param: category keys (Expenses::Expense::Category),
    # none if absent.
    CategoryParam = Types::Array[Expenses::Expense::Category].default([].freeze)

    query_schema(
      state: StateFilter::Param,
      category: CategoryParam,
      category_status: ReviewFilter::CategoryParam,
      vat_status: ReviewFilter::VatParam,
      q?: Types::String.nullable,
      from?: Types::Date.nullable,
      to?: Types::Date.nullable,
      page: Types::Integer[1..].default(1)
    )

    on Expenses::ExpenseList::Projected, Expenses::Ledger::Projected

    def channel_names = ['expenses.>', *SYSTEM_CHANNELS]

    # The list's URL for +states+, +categories+, +category_statuses+,
    # +vat_statuses+, +search+, the dates +from+ and +to+, and +page+.
    def self.path_for(states: [], categories: [], category_statuses: [], vat_statuses: [], search: nil, from: nil, to: nil,
                      page: 1)
      query = states.map { "state[]=#{it}" } + categories.map { "category[]=#{it}" } +
              category_statuses.map { "category_status[]=#{it}" } + vat_statuses.map { "vat_status[]=#{it}" }
      query << "q=#{URI.encode_www_form_component(search)}" if search
      query << "from=#{from.iso8601}" if from
      query << "to=#{to.iso8601}" if to
      query << "page=#{page}" if page > 1
      query.empty? ? path : "#{path}?#{query.join('&')}"
    end

    def self.load(params, _ctx)
      db = Sidereal.config['db']
      search = params[:q].to_s.strip
      filters = { states: params[:state], categories: params[:category], category_statuses: params[:category_status],
                  vat_statuses: params[:vat_status], search: (search unless search.empty?), from: params[:from], to: params[:to] }
      page = params[:page]
      rows, total = Expenses::ExpenseList.page(db, **filters, page:, per_page: PER_PAGE)
      # Past the end (fewer rows since the link was made): the last page.
      if rows.empty? && page > 1
        page = [(total + PER_PAGE - 1) / PER_PAGE, 1].max
        rows, total = Expenses::ExpenseList.page(db, **filters, page:, per_page: PER_PAGE)
      end
      # Each group's counts are within the other group's choice.
      new(rows:, total:, **filters, page:, counts: Expenses::ExpenseList.counts(db, **filters.except(:states)),
          category_counts: Expenses::ExpenseList.category_counts(db, **filters.except(:categories)),
          category_status_counts: Expenses::ExpenseList.status_counts(db, :category_statuses, **filters.except(:category_statuses)),
          vat_status_counts: Expenses::ExpenseList.status_counts(db, :vat_statuses, **filters.except(:vat_statuses)),
          ledger_total: ledger_total(db, **filters),
          month_totals: Expenses::Ledger.months(db, Sidereal.config['reporting_currency'], categories: filters[:categories],
                                                                                    matching: Expenses::ExpenseList.search(db, filters[:search])))
    end

    # The filed expenses in the dates, categories and search chosen, or
    # this month's: whatever the states and statuses, as every filed one's
    # category and VAT treatment are a person's.
    def self.ledger_total(db, from:, to:, categories:, search:, **)
      currency = Sidereal.config['reporting_currency']
      matching = Expenses::ExpenseList.search(db, search)
      if from || to
        Expenses::Ledger.total(db, currency, from:, to:, categories:, matching:)
      else
        Expenses::Ledger.month(db, currency, categories:, matching:)
      end
    end

    def initialize(rows:, total:, states:, categories:, from:, to:, page:, counts:, category_counts:, ledger_total:,
                   month_totals:, search: nil, category_statuses: [], vat_statuses: [], category_status_counts: {},
                   vat_status_counts: {})
      @rows = rows
      @total = total
      @states = states
      @categories = categories
      @category_statuses = category_statuses
      @vat_statuses = vat_statuses
      @category_status_counts = category_status_counts
      @vat_status_counts = vat_status_counts
      @search = search
      @category_counts = category_counts
      @from = from
      @to = to
      @page = page
      @counts = counts
      @ledger_total = ledger_total
      @month_totals = month_totals
    end

    # Going from the list to the list again (a year expanded, a filter, a
    # page) is a view transition, where browsers have them: the chart's
    # years animate to their new widths (month_chart.css), and the rest
    # changes at once. Only here, not in a stylesheet: a transition takes
    # both pages opting in, so links to and from other pages stay instant.
    # Not for anyone who'd rather have less motion.
    VIEW_TRANSITIONS = <<~CSS
      @media (prefers-reduced-motion: no-preference) {
        @view-transition { navigation: auto; }
      }
      ::view-transition-old(root), ::view-transition-new(root) { animation: none; }
    CSS

    def view_template
      div(id: 'expenses-page', class: 'expenses-page') do
        style { raw safe(VIEW_TRANSITIONS) }
        header(class: 'expenses-page__header') do
          div do
            h1(class: 'expenses-page__title') { 'All expenses' }
            a(href: NewExpensePage.path, class: 'button') { 'Add one by hand' }
          end
          render Components::LedgerTotal.new(@ledger_total, categories: @categories, search: @search)
        end
        render Components::MonthChart.new(@month_totals, from: @from, to: @to, search: @search, **list_filters)

        # One plain GET form for every filter, the states in the sidebar and
        # the dates above the list: changing one reloads the list with them
        # all, from the first page.
        form(class: 'expenses-page__body', action: self.class.path, method: 'get', data: { 'on:change' => 'el.submit()' }) do
          render_filters
          # The dates are the chart's, the search the top bar's: kept here,
          # so ticking a state keeps them.
          input(type: 'hidden', name: 'q', value: @search) if @search
          input(type: 'hidden', name: 'from', value: @from.iso8601) if @from
          input(type: 'hidden', name: 'to', value: @to.iso8601) if @to
          section(class: 'expenses-page__list', aria: { label: 'Expenses' }) do
            render_summary
            render Components::ExpenseRows.new(@rows) if @rows.any?
            render_pager
          end
        end
      end
    end

    private

    def pages = [(@total + PER_PAGE - 1) / PER_PAGE, 1].max

    def filtered? = list_filters.values.any?(&:any?) || @search || @from || @to

    # The sidebar's filters, as path_for takes them.
    def list_filters
      { states: @states, categories: @categories, category_statuses: @category_statuses, vat_statuses: @vat_statuses }
    end

    # The categories with how many have each, then the states, each with
    # its stage's colour and how many are in it, then whose category and
    # VAT treatment it is: each in the dates chosen, and the other groups'
    # choices.
    def render_filters
      aside(class: 'filters', aria: { label: 'Filters' }) do
        render_category_filters
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
        render_status_filters('Category', 'category_status[]', ReviewFilter::CATEGORY, @category_statuses, @category_status_counts)
        render_status_filters('VAT treatment', 'vat_status[]', ReviewFilter::VAT, @vat_statuses, @vat_status_counts)
        # Without JavaScript the change doesn't submit: this does.
        noscript { button(type: 'submit', class: 'button') { 'Apply' } }
        a(class: 'filters__clear', href: self.class.path) { 'Clear filters' } if filtered?
      end
    end

    # Only categories some expense has, or that are ticked: there are many.
    # In CategoryList's order: the baseline's, then the rest by name.
    def render_category_filters
      shown = Expenses::CategoryList.all(Sidereal.config['db'])
                                    .select { @category_counts.key?(it.key) || @categories.include?(it.key) }
      return if shown.empty?

      fieldset(class: 'filters__group') do
        legend(class: 'filters__legend') { 'Category' }
        shown.each do |choice|
          key = choice.key
          label(class: 'filter filter--category') do
            input(type: 'checkbox', name: 'category[]', value: key, checked: @categories.include?(key))
            span(class: 'filter__label') { choice.label }
            span(class: 'filter__count') { @category_counts.fetch(key, 0).to_s }
          end
        end
      end
    end

    def render_status_filters(legend, name, options, chosen, counts)
      fieldset(class: 'filters__group') do
        legend(class: 'filters__legend') { "#{legend} is" }
        options.each do |option|
          label(class: 'filter filter--status') do
            input(type: 'checkbox', name:, value: option.key, checked: chosen.include?(option.key))
            span(class: 'filter__label') { option.label }
            span(class: 'filter__count') { counts.fetch(option.key, 0).to_s }
          end
        end
      end
    end

    def render_summary
      p(class: 'expenses-page__summary') do
        if @total.zero?
          plain(filtered? ? 'No expenses match the filters. ' : 'No expenses yet. ')
          if filtered?
            a(href: self.class.path) { 'Clear filters' }
          else
            a(href: '/') { 'Upload a receipt' }
            plain ' or '
            a(href: NewExpensePage.path) { 'add one by hand' }
          end
        else
          first = ((@page - 1) * PER_PAGE) + 1
          last = [first + @rows.size - 1, @total].min
          plain "#{first}–#{last} of #{@total}"
          render_search_summary
        end
      end
    end

    # What it's searched for, and a link to the list without the search.
    def render_search_summary
      return unless @search

      plain ' matching '
      strong { "“#{@search}”" }
      plain ' · '
      a(href: self.class.path_for(**list_filters, from: @from, to: @to)) { 'Clear search' }
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
        a(class: "pager__link pager__link--#{rel}", href: self.class.path_for(**list_filters, search: @search, from: @from, to: @to, page:), rel:) { text }
      else
        span(class: "pager__link pager__link--#{rel} pager__link--disabled", aria: { hidden: 'true' }) { text }
      end
    end
  end
end
