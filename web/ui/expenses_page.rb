# frozen_string_literal: true

module UI
  # Every upload, newest first, a page at a time, with filters in a sidebar:
  # for now, by state (UI::StateFilter). Live: it re-renders whenever the
  # read model commits.
  #
  # The filters and the page number are in the query string
  # (?state[]=reviewing&page=2). App#params merges the query into the page's
  # params, and the layout puts those in the params signal, so a live
  # re-render keeps them too.
  class ExpensesPage < Sidereal::Page
    path '/expenses'

    PER_PAGE = 25

    on Expenses::Submissions::Projected, Expenses::UsdLedger::Projected

    def channel_name = 'expenses.>'

    # The list's URL for +states+ and +page+.
    def self.path_for(states: [], page: 1)
      query = states.map { "state[]=#{it}" }
      query << "page=#{page}" if page > 1
      query.empty? ? path : "#{path}?#{query.join('&')}"
    end

    def self.load(params, _ctx)
      db = Sidereal.config['db']
      states = StateFilter.parse(params[:state])
      page = [params[:page].to_i, 1].max
      rows, total = Expenses::Submissions.page(db, states:, page:, per_page: PER_PAGE)
      # Past the end (fewer rows since the link was made): the last page.
      if rows.empty? && page > 1
        page = [(total + PER_PAGE - 1) / PER_PAGE, 1].max
        rows, total = Expenses::Submissions.page(db, states:, page:, per_page: PER_PAGE)
      end
      new(rows:, total:, states:, page:, counts: Expenses::Submissions.counts(db), month: Expenses::UsdLedger.month(db))
    end

    def initialize(rows:, total:, states:, page:, counts:, month:)
      @month = month
      @rows = rows
      @total = total
      @states = states
      @page = page
      @counts = counts
    end

    def view_template
      div(id: 'expenses-page', class: 'expenses-page') do
        header(class: 'expenses-page__header') do
          h1(class: 'expenses-page__title') { 'All expenses' }
          render Components::MonthTotal.new(@month)
        end

        div(class: 'expenses-page__body') do
          render_filters
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

    # A plain GET form: choosing a state reloads the list with it, from the
    # first page. Each option shows its stage's colour and how many are in it.
    def render_filters
      aside(class: 'filters', aria: { label: 'Filters' }) do
        form(action: self.class.path, method: 'get', data: { 'on:change' => 'el.submit()' }) do
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
        end
        a(class: 'filters__clear', href: self.class.path) { 'Clear filters' } if @states.any?
      end
    end

    def render_summary
      p(class: 'expenses-page__summary') do
        if @total.zero?
          plain(@states.any? ? 'No expenses in the states chosen. ' : 'Nothing uploaded yet. ')
          a(href: @states.any? ? self.class.path : '/') { @states.any? ? 'Clear filters' : 'Upload a receipt' }
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
        a(class: "pager__link pager__link--#{rel}", href: self.class.path_for(states: @states, page:), rel:) { text }
      else
        span(class: "pager__link pager__link--#{rel} pager__link--disabled", aria: { hidden: 'true' }) { text }
      end
    end
  end
end
