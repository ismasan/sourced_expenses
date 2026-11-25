# frozen_string_literal: true

module UI
  # An expense entered by hand (Components::NewExpenseForm): once added, it's
  # on its own page to choose its category, confirm its VAT treatment and
  # file, as one read from a document is.
  class NewExpensePage < Page
    path '/expenses/new'

    def self.load(_params, _ctx) = new

    def view_template
      div(id: 'new-expense-page', class: 'record-page') do
        p(class: 'record-page__back') { a(href: ExpensesPage.path) { 'All expenses' } }
        header(class: 'record-page__header') do
          h1(class: 'record-page__title') { 'New expense' }
        end
        p(class: 'panel-lead') do
          plain 'Fill it in by hand. You’ll choose its category and confirm its VAT treatment next. To read one from a receipt, '
          a(href: '/') { 'upload it' }
          plain ' instead.'
        end
        render Components::NewExpenseForm.new
      end
    end
  end
end
