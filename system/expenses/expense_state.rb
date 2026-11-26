# frozen_string_literal: true

module Expenses
  # What an Expense machine knows about its expense: the document attached
  # to it, or the system it was imported from, if any, the form a person
  # reviews (a draft's tentative figures, a person's own, or its source's), the filed expense, its total in the reporting
  # currency, its category and its VAT treatment. Nothing about scanning.
  # The machine's position is the machine's own.
  class ExpenseState
    attr_accessor :expense_id, :document_id, :filing_country, :vendor, :drafted, :entered, :draft, :filed,
                  :source, :external_id, :external_url, :imported, :source_category, :source_vat_treatment,
                  :confirmed_vat_treatment, :converted, :conversion_failure, :category,
                  :category_suggestion, :category_chosen, :categorization_failure, :uploads

    def initialize
      @draft = {}
      @uploads = {}
    end

    # Where it was uploaded to +destination+, or nil: its +external_id+
    # and +external_url+ there, the last +failure+ ({ reason:, unsure: }),
    # and whether it was +deleted+ there.
    # @return [Hash, nil]
    def upload(destination) = uploads[destination]

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

    # ---- Imported ----

    # Whether it was imported from another system (+source+).
    def imported? = !source.nil?

    # Whether an import has all it takes to file it as it is: a category, a
    # VAT treatment and a description. Its source's books are trusted.
    def self.complete_import?(payload)
      !payload[:category].nil? && !payload[:vat_treatment].nil? && !payload[:description].to_s.strip.empty?
    end

    # Its source's figures (the first import, or changed there since) are
    # the form. Its source's category is a suggestion, until one is chosen;
    # its VAT treatment, the one suggested. A complete import confirms both
    # with their own events (CategoryChosen, VatTreatmentConfirmed).
    def import!(payload)
      self.imported = payload
      self.source = payload[:source]
      self.external_id = payload[:external_id]
      self.external_url = payload[:external_url]
      self.filing_country = payload[:filing_country]
      self.source_category = payload[:source_category]
      self.source_vat_treatment = payload[:vat_treatment]
      self.draft = payload.slice(*Expense::DRAFT)
      return if category_chosen? || payload[:category].nil?

      self.category = payload[:category]
      self.category_suggestion = { category: payload[:category], source: }
    end

    # Whether ImportExpense with +payload+ (without the expense's id) is this
    # expense's, changed at its source since it was last imported.
    def import_changed?(payload)
      imported? && payload[:source] == source && payload[:external_id] == external_id && payload != imported
    end

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

    # The treatment to suggest for +draft+ (Expense::DRAFT's fields): its
    # source's (+source_vat_treatment+, an imported expense's), or else the
    # rule's, or nil with no figures to go on (nothing read, nothing filled
    # in yet). ExpenseList suggests through here too.
    def self.suggested_vat_treatment(draft, filing_country:, source_vat_treatment: nil)
      return source_vat_treatment if source_vat_treatment
      return nil if draft[:tax_amount_cents].nil?

      infer_vat_treatment(
        reverse_charge: draft[:reverse_charge] == true, tax_amount_cents: draft[:tax_amount_cents],
        supplier_country_code: draft[:supplier_country_code], filing_country:
      )
    end

    # The rule's treatment for the form as it stands (the draft, or what
    # was filed).
    def suggested_vat_treatment = self.class.suggested_vat_treatment(draft, filing_country:, source_vat_treatment:)

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
