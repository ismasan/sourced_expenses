# frozen_string_literal: true

module Expenses
  # What an Expense machine knows about its expense: the document attached
  # to it, if any, the form a person reviews (a draft's tentative figures,
  # or a person's own), the filed expense, its total in the reporting
  # currency, its category and its VAT treatment. Nothing about scanning.
  # The machine's position is the machine's own.
  class ExpenseState
    attr_accessor :expense_id, :document_id, :filing_country, :vendor, :drafted, :entered, :draft, :filed,
                  :confirmed_vat_treatment, :converted, :conversion_failure, :category,
                  :category_suggestion, :category_chosen, :categorization_failure

    def initialize
      @draft = {}
    end

    # Whether an uploaded document is attached: it was read from one.
    def document? = !document_id.nil?

    # ---- The form ----

    # A draft (the first, or its document read again) is the form from now
    # on, its figures tentative.
    def draft!(payload)
      self.drafted = payload
      self.filing_country = payload[:filing_country]
      self.vendor = payload[:vendor]
      self.draft = payload.slice(*Expense::DRAFT)
    end

    # A person's own figures are the form.
    def enter!(payload)
      self.entered = true
      self.filing_country = payload[:filing_country]
      self.draft = payload.slice(*Expense::DRAFT)
    end

    # Whether the form's figures are a person's (entered, or filed) rather
    # than a draft's.
    def entered? = entered == true || !filed.nil?

    # Whether DraftExpenseFromDocument with +payload+ (without the expense's
    # and the document's ids) would change nothing: the same draft again.
    def drafted?(payload) = drafted == payload

    # ---- VAT treatment ----

    # Never the model's call: it depends on whose books the expense is in,
    # and a wrong answer in the taxpayer's favour creates a liability. Tried
    # in order; unproven VAT comes out foreign_vat, so an unreviewed expense
    # under-claims. +import+ is only ever a person's choice.
    def self.infer_vat_treatment(reverse_charge:, tax_amount_cents:, supplier_country_code:, filing_country:)
      return 'reverse_charge' if reverse_charge
      return 'no_vat' if tax_amount_cents.zero?
      return 'domestic' if supplier_country_code == filing_country

      'foreign_vat'
    end

    # The rule's treatment for +draft+ (Expense::DRAFT's fields), or nil
    # with no figures to go on (nothing read, nothing filled in yet).
    def self.suggested_vat_treatment(draft, filing_country:)
      return nil if draft[:tax_amount_cents].nil?

      infer_vat_treatment(
        reverse_charge: draft[:reverse_charge] == true, tax_amount_cents: draft[:tax_amount_cents],
        supplier_country_code: draft[:supplier_country_code], filing_country:
      )
    end

    # The rule's treatment for the form as it stands (the draft, or what
    # was filed).
    def suggested_vat_treatment = self.class.suggested_vat_treatment(draft, filing_country:)

    # The treatment in force: the person's, or else the rule's suggestion.
    def vat_treatment = confirmed_vat_treatment || suggested_vat_treatment

    def vat_treatment_confirmed? = !confirmed_vat_treatment.nil?

    # Another country's VAT, as far as the rule can tell, or nothing to tell
    # from: a person should look closely.
    def vat_needs_review? = [nil, 'foreign_vat'].include?(suggested_vat_treatment)

    # ---- The filed total in the reporting currency ----

    # What's converted: the filed expense's total, VAT included.
    def filed_total_cents = filed && (filed[:net_price_cents] + filed[:tax_amount_cents])

    # Whether a conversion of +amount_cents+ in +currency+ on +incurred_on+
    # is of the expense as filed now.
    def converting?(currency:, amount_cents:, incurred_on:)
      !filed.nil? && currency == filed[:currency] && amount_cents == filed_total_cents &&
        incurred_on == filed[:incurred_on]
    end

    # Filing again forgets a conversion, or a failure, for what's no longer
    # the filed total. One for the same total stays.
    def forget_stale_conversion
      self.converted = nil if converted && !converting?(**converted.slice(:currency, :amount_cents, :incurred_on))
      if conversion_failure && !converting?(**conversion_failure.slice(:currency, :amount_cents, :incurred_on))
        self.conversion_failure = nil
      end
    end

    # ---- The category ----

    # +category+ is the one in force: the person's, or else the model's
    # latest suggestion (+category_suggestion+: category, probability and
    # the description it was for).
    def category_chosen? = category_chosen == true
  end
end
