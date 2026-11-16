# frozen_string_literal: true

require 'date'

module Expenses
  # What an Expense machine knows about its document: the upload, the current
  # scan's results, the form a person reviews, and the filed expense. The
  # machine's position (which step of the scan it's at) is the machine's own.
  #
  # The decisions between LLM calls live here, as plain Ruby the chart's
  # guards and handlers call: whether an extraction is plausible, whether its
  # date needs a second look, how extracted floats become an expense, and
  # which VAT treatment a filed expense gets.
  class Document
    # A receipt normally reaches us within weeks of the purchase, so an
    # all-numeric date that lands far from the reference date (or after it)
    # is more often a misread digit or a swapped day and month than a
    # genuinely old receipt. Spelled-out months ("11 Aug 2026") carry neither
    # risk.
    RECHECK_DATE_OLDER_THAN_DAYS = 60
    NUMERIC_DATE = %r{\d{1,4}[./-]\d{1,2}[./-]\d{2,4}}

    attr_accessor :expense_id, :filename, :content_type, :file_ref, :filing_country,
                  :reference_date, :processed_file_ref, :extraction, :verification,
                  :date_recheck, :cleanup, :failure, :draft, :filed,
                  :vat_treatment, :vat_treatment_confirmed, :converted,
                  :conversion_failure
    attr_reader :scans

    def initialize
      @scans = 0
      @draft = {}
    end

    # A new scan of the same file forgets the last one's results. The form
    # a person already saved (filed) stays.
    def start_scan(reference_date)
      @scans += 1
      @reference_date = reference_date
      @processed_file_ref = nil
      @extraction = nil
      @verification = nil
      @date_recheck = nil
      @cleanup = nil
      @failure = nil
    end

    # ---- Plausibility: is the extraction good enough to go on with? ----

    # What looks wrong with the extraction. Any at all and a narrower call
    # asks whether the document is a receipt in the first place; these are
    # what it's told went wrong.
    def extraction_errors
      return ['No data extracted'] unless extraction

      errors = []
      total = extraction[:total_amount]
      net = extraction[:net_amount]

      if total.nil?
        errors << 'Missing total amount'
      elsif !currency_amount?(total)
        errors << "Invalid total amount format (#{total})"
      end
      errors << "Invalid net amount format (#{net})" if !net.nil? && !currency_amount?(net)
      errors << 'Missing currency' if blank?(extraction[:currency])
      if blank?(extraction[:date])
        errors << 'Missing date'
      elsif extracted_date.nil?
        errors << "Invalid date format (#{extraction[:date]})"
      end
      errors << 'Missing description' if blank?(extraction[:description])
      errors << 'Low confidence extraction' if extraction[:confidence] == 'low'
      errors
    end

    def implausible? = extraction_errors.any?

    # ---- The date: worth a second, narrower look? ----

    def extracted_date = parse_date(extraction&.dig(:date))

    def date_suspect?
      printed = extraction&.dig(:date_as_printed)
      return false if blank?(printed) || !printed.match?(NUMERIC_DATE)

      date = extracted_date
      return false unless date

      date > reference_date || date < reference_date - RECHECK_DATE_OLDER_THAN_DAYS
    end

    # The recheck's date, if it should replace the first reading: never one
    # after the reference date (we'd trade one bad reading for another), and
    # only when it differs.
    def date_correction(rechecked)
      date = parse_date(rechecked)
      return nil if date.nil? || date > reference_date || date == extracted_date

      date
    end

    # The re-read date (ISO 8601) replaces the first, and the datetime goes:
    # it carried the old date, and only the date was re-read.
    def correct_date(date)
      extraction[:date] = date
      extraction[:datetime] = nil
    end

    # ---- From extracted floats to an expense ----

    # The prefilled form: amounts in integer cents, a receipt showing only a
    # total booked as net with zero tax. Cleaned-up text replaces what the
    # extraction read, where the cleanup ran.
    def attributes
      return {} unless extraction

      total = extraction[:total_amount].to_f
      net = extraction[:net_amount]&.to_f
      tax = extraction[:tax_amount]&.to_f

      if net.nil? && tax
        net = total - tax
      elsif net.nil?
        net = total
        tax = 0
      end
      tax ||= 0

      vendor = extraction[:vendor_name]
      description = cleanup&.dig(:description) || extraction[:description]
      description = vendor ? "#{vendor} - Purchase" : 'Expense' if blank?(description)

      {
        description:,
        net_price_cents: (net * 100).round,
        tax_amount_cents: (tax * 100).round,
        tax_description: cleanup ? cleanup[:tax_description] : extraction[:tax_description],
        currency: extraction[:currency] || 'EUR',
        incurred_on: extracted_date,
        supplier_country_code: country_code(extraction[:supplier_country_code]),
        reverse_charge: extraction[:reverse_charge] == true,
        payment_reference: extraction[:payment_reference]
      }
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

    # Another country's VAT, as far as the rule can tell: a person should look.
    def vat_needs_review? = vat_treatment == 'foreign_vat'

    def vat_treatment_confirmed? = vat_treatment_confirmed == true

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

    private

    # At most two decimals, as money is. Integers and 10.5 or -10.99 pass.
    def currency_amount?(value)
      value.is_a?(Numeric) && (value - value.round(2)).abs < 0.0001
    end

    def parse_date(value) = Types.iso_date(value)

    # ISO 3166-1 alpha-2, or nothing. Two letters, at least: checking it's a
    # real country needs a country list.
    def country_code(code)
      return nil if blank?(code)

      code = code.to_s.strip.upcase[0, 2]
      code.match?(/\A[A-Z]{2}\z/) ? code : nil
    end

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
