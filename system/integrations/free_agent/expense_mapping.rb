# frozen_string_literal: true

require 'bigdecimal'
require 'date'

module Integrations
  module FreeAgent
    # A FreeAgent expense (its API's JSON object) as Expenses::Expense's
    # ImportExpense: FreeAgent's details stop here.
    #
    #   ExpenseMapping.payload(expense, categories: client.categories, filing_country: 'GB', web_url: client.web_url)
    #   # => { expense_id: 'freeagent-123', source: 'freeagent', external_id: '123', ... }, or nil
    #
    # - Its id is its url's last segment: the expense's here is freeagent-<id>.
    #   Its page on the company's FreeAgent site (+web_url+) is
    #   <web_url>/users/<its claimant's id>/expenses/<id>/edit, if it has a
    #   claimant and +web_url+ is known.
    # - Amounts are decimal strings, negative for money paid out to the
    #   claimant (an expense) and positive for a refund due from them: flipped,
    #   so an expense is a positive cost here and a refund a negative one.
    # - Its category (a url) is the baseline's (Expenses::CATEGORIES) where
    #   the names match, whatever their case or punctuation, or one in
    #   ALIASES; otherwise one of its own, keyed from its name ("Use of home"
    #   is use_of_home). Either way it's the expense's suggested category, and
    #   +source_category+ its name.
    # - Its VAT treatment is FreeAgent's: reverse charged (EC goods and
    #   services before 2021 included), no VAT (exempt, out of scope, or
    #   none), or else domestic, reclaimed on the company's own return.
    # - Mileage claims, which have no amount of their own, are skipped (nil),
    #   and so is one without a url, a date or a currency.
    module ExpenseMapping
      SOURCE = 'freeagent'

      # FreeAgent category names (as normalized by .normalize) that are one of
      # the baseline's under another name, and which. Without one, a category
      # is its own. `bin/sid expenses import --categories freeagent` lists
      # them, and which are their own.
      ALIASES = {}.freeze

      REVERSE_CHARGE = ['Reverse Charge', 'EC Goods', 'EC Services'].freeze
      NO_VAT = %w[EXEMPT OUT_OF_SCOPE].freeze

      # @param expense [Hash] FreeAgent's JSON object
      # @param categories [Hash{String => Client::Category}] by url
      # @return [Hash, nil] ImportExpense's payload, or nil for an expense not imported
      def self.payload(expense, categories:, filing_country:, web_url: nil)
        return if expense['category'] == 'Mileage' || expense['gross_value'].nil?
        return if %w[url dated_on currency].any? { present(expense[it]).nil? }

        external_id = expense.fetch('url').split('/').last
        gross = -decimal(expense['gross_value'])
        tax = -decimal(expense['sales_tax_value'])
        category = categories[expense['category']]
        {
          expense_id: "#{SOURCE}-#{external_id}", source: SOURCE, external_id:, filing_country:,
          external_url: page_url(web_url, expense['user'], external_id),
          description: present(expense['description']) || category&.description,
          net_price_cents: cents(gross - tax), tax_amount_cents: cents(tax),
          tax_description: tax_description(expense), currency: expense.fetch('currency').upcase,
          incurred_on: Date.iso8601(expense.fetch('dated_on')),
          reverse_charge: REVERSE_CHARGE.include?(expense['ec_status']),
          payment_reference: present(expense['receipt_reference']),
          category: category && (ours(category.description) || Expenses.category_key(category.description)),
          source_category: category&.description,
          vat_treatment: vat_treatment(expense, tax)
        }
      end

      # The category of ours FreeAgent's +name+ is, or nil.
      def self.ours(name)
        key = normalize(name)
        ALIASES[key] || Expenses::CATEGORIES.find { |_, (label, _)| normalize(label) == key }&.first
      end

      # A name, for matching: lowercase letters and digits only, without "and"
      # ("Bank/Finance Charges" and "Bank and finance charges" are one).
      def self.normalize(name) = name.to_s.downcase.gsub(/&|\band\b/, ' ').gsub(/[^a-z0-9]/, '')

      def self.page_url(web_url, user, external_id)
        user_id = present(user)&.split('/')&.last
        "#{web_url}/users/#{user_id}/expenses/#{external_id}/edit" if web_url && user_id
      end

      def self.vat_treatment(expense, tax)
        return 'reverse_charge' if REVERSE_CHARGE.include?(expense['ec_status'])
        return 'no_vat' if NO_VAT.include?(expense['sales_tax_status']) || tax.zero?

        'domestic'
      end

      def self.tax_description(expense)
        rate = expense['sales_tax_rate'] && decimal(expense['sales_tax_rate'])
        "VAT #{rate.to_s('F').delete_suffix('.0')}%" if rate&.nonzero?
      end

      def self.decimal(value) = value.nil? ? BigDecimal('0') : BigDecimal(value.to_s)

      def self.cents(amount) = (amount * 100).round.to_i

      def self.present(value) = value.to_s.strip.empty? ? nil : value.to_s.strip

      private_class_method :page_url, :vat_treatment, :tax_description, :decimal, :cents, :present
    end
  end
end
