# frozen_string_literal: true

module UI
  # Every upload, newest first, a page at a time, with filters in a sidebar:
  # by state (UI::StateFilter), and by the expense's date, a whole month or
  # any range. Live: it re-renders whenever the read model commits.
  #
  # The header has the total in US dollars of the filed expenses in the
  # dates chosen, whatever the states, or this month's without dates.
  #
  # The filters and the page number are in the query string
  # (?state[]=filed&from=2025-11-01&to=2025-11-30&page=2), typed by the
  # query schema: an unknown state, a page below 1 or a date that isn't
  # YYYY-MM-DD is a 400. A blank date (an emptied field) is none. The layout
  # puts the params in the params signal, so a live re-render keeps them.
  class ExpensesPage < Sidereal::Page
    path '/expenses'

    PER_PAGE = 25

    query_schema(
      state: StateFilter::Param,
      from?: Types::Date.nullable,
      to?: Types::Date.nullable,
      page: Types::Integer[1..].default(1)
    )

    on Expenses::Submissions::Projected, Expenses::UsdLedger::Projected

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
          months: Expenses::Submissions.months(db), usd_total: usd_total(db, **filters))
    end

    # The filed expenses in the dates chosen, or this month's.
    def self.usd_total(db, from:, to:, **)
      from || to ? Expenses::UsdLedger.total(db, from:, to:) : Expenses::UsdLedger.month(db)
    end

    def initialize(rows:, total:, states:, from:, to:, page:, counts:, months:, usd_total:)
      @rows = rows
      @total = total
      @states = states
      @from = from
      @to = to
      @page = page
      @counts = counts
      @months = months
      @usd_total = usd_total
    end

    def view_template
      div(id: 'expenses-page', class: 'expenses-page') do
        header(class: 'expenses-page__header') do
          h1(class: 'expenses-page__title') { 'All expenses' }
          render Components::UsdTotal.new(@usd_total)
        end

        # One plain GET form for every filter, the states in the sidebar and
        # the dates above the list: changing one reloads the list with them
        # all, from the first page.
        form(class: 'expenses-page__body', action: self.class.path, method: 'get', data: { 'on:change' => 'el.submit()' }) do
          render_filters
          section(class: 'expenses-page__list', aria: { label: 'Expenses' }) do
            render_dates
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

    # Pick a whole month, or any dates. The month list has no name of its
    # own: choosing one fills in the two dates, which the form then submits
    # (?from=2025-11-01&to=2025-11-30). It shows the month the dates are.
    MONTH_PICKED = <<~JS.tr("\n", ' ').freeze
      const [from, to] = el.value ? el.value.split('/') : ['', ''];
      el.form.elements.from.value = from;
      el.form.elements.to.value = to
    JS

    def render_dates
      fieldset(class: 'date-filters') do
        legend(class: 'visually-hidden') { 'Dates' }
        label(class: 'date-filters__field date-filters__field--month') do
          span(class: 'date-filters__label') { 'Month' }
          select(data: { 'on:change' => MONTH_PICKED }) do
            option(value: '', selected: !@from && !@to) { 'All dates' }
            option(value: 'custom', selected: true, disabled: true) { 'Custom dates' } if (@from || @to) && !month_picked
            months.each do |first|
              last = first.next_month - 1
              option(value: "#{first.iso8601}/#{last.iso8601}", selected: month_picked == first) { first.strftime('%B %Y') }
            end
          end
        end
        date_field('from', 'From', @from)
        date_field('to', 'To', @to)
      end
    end

    def date_field(name, text, value)
      label(class: 'date-filters__field') do
        span(class: 'date-filters__label') { text }
        input(type: 'date', name:, value: value&.iso8601)
      end
    end

    # The months with expenses dated in them, and this one, latest first.
    def months = (@months | [Date.new(Date.today.year, Date.today.month, 1)]).sort.reverse

    # The month the dates are, if they're a whole one.
    def month_picked
      return unless @from && @to && @from.day == 1 && @to == @from.next_month - 1

      @from
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
