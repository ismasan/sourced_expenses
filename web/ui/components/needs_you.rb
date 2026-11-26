# frozen_string_literal: true

module UI
  module Components
    # The home page's list of what's waiting for a person, newest first:
    # expenses to review or file, then documents that couldn't be read,
    # to fill in by hand, scan again or discard. Re-rendered by its id
    # whenever either read model commits.
    class NeedsYou < Phlex::HTML
      PER_PAGE = 50

      def self.load(db = Sidereal.config['db'])
        new(Expenses::ExpenseList.page(db, states: Expenses::ExpenseList::NEEDS_YOU, per_page: PER_PAGE),
            Documents::DocumentList.page(db, states: Documents::DocumentList::NEEDS_YOU, per_page: PER_PAGE))
      end

      # @param expenses [Array(Array<Expenses::ExpenseList::Row>, Integer)] the latest, and how many in all
      # @param documents [Array(Array<Documents::DocumentList::Row>, Integer)] the latest, and how many in all
      def initialize(expenses = [[], 0], documents = [[], 0])
        @expenses, @expenses_total = expenses
        @documents, @documents_total = documents
      end

      def view_template
        section(id: 'needs-you', class: 'submissions', aria: { labelledby: 'needs-you-title' }) do
          h2(id: 'needs-you-title', class: 'submissions__title') do
            plain 'Needs you'
            span(class: 'submissions__count') { (@expenses_total + @documents_total).to_s }
          end

          if @expenses.empty? && @documents.empty?
            p(class: 'submissions__empty') do
              plain 'Nothing needs you right now. Drop receipts above, '
              a(href: NewExpensePage.path) { 'add an expense by hand' }
              plain ', or '
              a(href: '/expenses') { 'see all expenses' }
              plain '.'
            end
            next
          end

          render ExpenseRows.new(@expenses) if @expenses.any?
          if @expenses_total > @expenses.size
            p(class: 'submissions__more') do
              a(href: ExpensesPage.path_for(states: Expenses::ExpenseList::NEEDS_YOU)) { "See all #{@expenses_total}" }
            end
          end
          if @documents.any?
            h3(class: 'submissions__subtitle') { 'Couldn’t be read' }
            render DocumentRows.new(@documents)
          end
        end
      end
    end
  end
end
