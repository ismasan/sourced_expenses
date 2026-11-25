# frozen_string_literal: true

module UI
  module Components
    # The first few expenses matching what's typed in the search box
    # (Search), newest first, each a link to its page, and a link to the
    # list of them all. Patched into the box's pane by GET /search.
    class SearchPreview < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/search_preview.css', path: 'search_preview.css'

      LIMIT = 6

      # The first LIMIT matches for +query+, and how many there are.
      def self.for(query)
        rows, total = Expenses::ExpenseList.page(Sidereal.config['db'], search: query, per_page: LIMIT)
        new(query, rows, total)
      end

      # @param query [String]
      # @param rows [Array<Expenses::ExpenseList::Row>]
      # @param total [Integer] how many match in all
      def initialize(query, rows, total)
        @query = query
        @rows = rows
        @total = total
      end

      def view_template
        div(id: 'search-preview', class: 'search-preview', aria: { live: 'polite' }) do
          if @rows.empty?
            p(class: 'search-preview__empty') do
              plain 'Nothing matches '
              strong { "“#{@query}”" }
            end
          else
            ol(class: 'search-preview__list') { @rows.each_with_index { |sub, i| row(sub, i) } }
            # Ids for the search box's aria-activedescendant, as it highlights them.
            a(id: 'search-result-all', class: 'search-preview__all', href: ExpensesPage.path_for(search: @query)) do
              @total == 1 ? 'See it in the list' : "See all #{@total} in the list"
            end
          end
        end
      end

      private

      def row(sub, index)
        status = Status.for(sub.machine)
        li(class: "search-preview__item search-preview__item--#{status.stage}") do
          a(id: "search-result-#{index}", class: 'search-preview__link', href: "/expenses/#{sub.expense_id}") do
            span(class: 'search-preview__description') { sub.description || 'New expense' }
            span(class: 'search-preview__amount') { Money.format(sub.total_cents, sub.currency) } if sub.total_cents && sub.currency
            span(class: 'search-preview__meta') do
              plain [sub.incurred_on&.strftime('%-d %b %Y'), sub.category && Expenses.category_label(sub.category),
                     status.label].compact.join(' · ')
            end
          end
        end
      end
    end
  end
end
