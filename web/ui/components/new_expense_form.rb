# frozen_string_literal: true

require 'securerandom'

module UI
  module Components
    # An expense entered by hand, with no document: the form, as the review
    # has it, sent as NewExpense. Its handler enters the expense
    # (Expenses::Expense::EnterExpense, with the filing country, which isn't
    # the browser's to say) and takes the browser to its page, where it's
    # reviewed and filed like any other.
    #
    # The expense's id is made when the form is rendered, not when it's
    # sent, so sending the same form twice is the same expense.
    class NewExpenseForm < Sidereal::Components::BaseComponent
      E = Expenses::Expense

      # The form's fields, as SaveExpense takes them, and the id it was
      # rendered with. Web only: never stored itself.
      NewExpense = Sidereal::Message.define('web.new_expense') do
        attribute :expense_id, Types::ExpenseID
        attribute :description, Types::String.present
        attribute :net_price_cents, Integer
        attribute :tax_amount_cents, Types::Integer.default(0)
        attribute :tax_description, Types::String.nullable
        attribute :currency, E::CurrencyCode
        attribute :incurred_on, Date
        attribute :supplier_country_code, E::CountryCode.nullable
        attribute :reverse_charge, Types::Boolean.default(false)
        attribute :payment_reference, Types::String.nullable
      end

      handle NewExpense do |cmd|
        dispatch E::EnterExpense, { **cmd.payload.to_h, filing_country: Sidereal.config['expenses.filing_country'] }
        browser.redirect "/expenses/#{cmd.payload.expense_id}"
      end

      include ExpenseFields

      # @param expense_id [String] the new expense's id, a fresh UUID by default
      # @param currency [String] the currency to start from
      def initialize(expense_id: SecureRandom.uuid, currency: Sidereal.config['reporting_currency'])
        @expense_id = expense_id
        @currency = currency
      end

      def view_template
        command NewExpense.new(payload: { expense_id: @expense_id, currency: @currency, tax_amount_cents: 0 }),
                class: 'review-form' do |f|
          f.payload_fields(expense_id: @expense_id)
          expense_fields(f)
          div(class: 'actions actions--final') do
            button(type: :submit, class: 'button button--primary') { 'Add expense' }
          end
        end
      end

      private

      def field(name, &)
        label(class: 'review-form__field') do
          span { name }
          yield
        end
      end
    end
  end
end
