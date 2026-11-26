# frozen_string_literal: true

require 'date'

module Documents
  # What a Document machine knows about its file: the upload and the current
  # scan's results. The machine's position (which step of the scan it's at)
  # is the machine's own.
  #
  # The decisions between LLM calls live here, as plain Ruby the chart's
  # guards and handlers call: whether an extraction is plausible, whether its
  # date needs a second look, and how extracted floats become the draft of
  # an expense (#prefill).
  class DocumentState
    # A receipt normally reaches us within weeks of the purchase, so an
    # all-numeric date that lands far from the reference date (or after it)
    # is more often a misread digit or a swapped day and month than a
    # genuinely old receipt. Spelled-out months ("11 Aug 2026") carry neither
    # risk.
    RECHECK_DATE_OLDER_THAN_DAYS = 60
    NUMERIC_DATE = %r{\d{1,4}[./-]\d{1,2}[./-]\d{2,4}}

    attr_accessor :document_id, :filename, :content_type, :file_ref, :filing_country,
                  :reference_date, :processed_file_ref, :extraction, :verification,
                  :date_recheck, :cleanup, :failure
    attr_reader :scans

    def initialize
      @scans = 0
    end

    # A new scan of the same file forgets the last one's results.
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

    # The draft of the expense the scan read: amounts in integer cents, a
    # receipt showing only a total booked as net with zero tax. Cleaned-up
    # text replaces what the extraction read, where the cleanup ran. Empty
    # before a scan has read anything.
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
        currency: currency_code(extraction[:currency]),
        incurred_on: extracted_date,
        supplier_country_code: country_code(extraction[:supplier_country_code]),
        reverse_charge: extraction[:reverse_charge] == true,
        payment_reference: extraction[:payment_reference],
        vendor:
      }
    end

    # The Expenses::Expense::DraftExpenseFromDocument payload for this document's expense: its id
    # is the document's, and its draft what the scan read, if anything
    # (+read: false+ for one filled in by hand).
    def prefill(read: true)
      { expense_id: document_id, document_id:, filing_country:, **(read ? attributes : {}) }
    end

    private

    # At most two decimals, as money is. Integers and 10.5 or -10.99 pass.
    def currency_amount?(value)
      value.is_a?(Numeric) && (value - value.round(2)).abs < 0.0001
    end

    def parse_date(value) = Types.iso_date(value)

    # ISO 4217, upcased, or nothing: a draft's currency is three letters
    # (Expenses::Expense::DraftExpenseFromDocument refuses anything else), so a symbol or a name
    # the model read ("€", "Euro") is left for the person to fill in. None
    # read at all is EUR, as before.
    def currency_code(code)
      return 'EUR' if blank?(code)

      code = code.to_s.strip.upcase
      code.match?(/\A[A-Z]{3}\z/) ? code : nil
    end

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
