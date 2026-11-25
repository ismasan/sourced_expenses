# frozen_string_literal: true

module UI
  # An expense's form fields (Expense::DRAFT's), for a command form whose
  # command has them: the review's SaveExpense and NewExpenseForm's. +f+ is
  # the form's builder; the includer has #field (a label around a field).
  module ExpenseFields
    private

    def expense_fields(f)
      field('Description') { f.text_field :description }
      div(class: 'review-form__row') do
        field('Net amount (cents)') { f.number_field :net_price_cents, step: 1 }
        field('VAT amount (cents)') { f.number_field :tax_amount_cents, step: 1 }
        field('Currency') { f.text_field :currency, maxlength: 3, placeholder: 'EUR' }
      end
      field('VAT description') { f.text_field :tax_description, placeholder: 'BTW 21%' }
      div(class: 'review-form__row') do
        field('Date') { f.date_field :incurred_on }
        field('Supplier country') { f.text_field :supplier_country_code, maxlength: 2, placeholder: 'GB' }
      end
      field('Payment reference') { f.text_field :payment_reference }
      label(class: 'review-form__check') do
        f.check_box :reverse_charge
        span { 'VAT reverse charged' }
      end
    end
  end
end
