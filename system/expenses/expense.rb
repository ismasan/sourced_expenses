# frozen_string_literal: true

require 'date'

module Expenses
  # One uploaded receipt or invoice, from the upload to a filed expense.
  #
  #   initial ─UploadDocument─▶ queued ─StartScan─▶ scanning ──on_final scanned─────────▶ reviewing ─done─▶ reviewed ─SaveExpense─▶ filed ⟲ SaveExpense
  #                                                (Scanning) ├on_final not_an_invoice─▶ rejected
  #                                                           ├on_final failed─────────▶ scan_failed
  #                                                           └after 10m: TimeOutScan──▶ scan_failed
  #
  #   reviewing:  category  ─ChooseCategory──────▶ category_confirmed
  #               vat       ─ConfirmVatTreatment─▶ vat_confirmed
  #
  #   rejected, scan_failed ─EnterManually─▶ reviewing
  #   reviewing, reviewed, rejected, scan_failed ─Rescan─▶ queued
  #   filed ─VoidExpense─▶ voided;  anything before filed ─DiscardDocument─▶ discarded
  #   reviewing, reviewed, filed ⟲ SuggestCategory | FailCategorization | ChooseCategory | ConfirmVatTreatment
  #
  # The model never writes the expense and never decides its tax treatment:
  # the scan prefills a form, and a person files it. Reviewing has two steps,
  # in either order: choosing the category (the model's suggestion, from
  # Expenses::Categorizer, until a person chooses one) and confirming the VAT
  # treatment (the rule's, Document#suggested_vat_treatment, until a person
  # confirms one). Only once both are done is the expense reviewed, and only
  # a reviewed expense can be filed.
  class Expense < Sourced::Machine
    partition_by expense_id: Types::ExpenseID
    message_prefix 'expenses'

    # The queue scans wait in (see Queued), 3 expenses scanning at once. Each
    # scan makes up to four model calls, one after another, so this caps the
    # model calls in flight for scanning.
    ScanQueue = WorkQueue.define('scans', capacity: 3)

    # How long a scan may take, every LLM call and its retries included,
    # before it's given up on.
    SCAN_TIMEOUT = ENV.fetch('SCAN_TIMEOUT', '10m')

    CurrencyCode = Types::String[/\A[A-Z]{3}\z/]
    CountryCode = Types::String[/\A[A-Z]{2}\z/]

    # ---- States ----

    Queued = State(:queued)
    Reviewing = State(:reviewing)
    CategoryConfirmed = State(:category_confirmed)
    VatConfirmed = State(:vat_confirmed)
    Reviewed = State(:reviewed)
    Filed = State(:filed)
    Rejected = State(:rejected)
    ScanFailed = State(:scan_failed)
    Discarded = State(:discarded)
    Voided = State(:voided)

    # ---- Commands ----

    # +file_ref+ is wherever the upload was stored; +filing_country+, the
    # country of the company whose books this is in. +reference_date+ is
    # "today" for the scan: the prompts resolve ambiguous dates towards it,
    # and passing it in keeps decisions deterministic.
    UploadDocument = Command(:upload_document) do
      attribute :expense_id, Types::ExpenseID
      attribute :filename, Types::String.present
      attribute :content_type, Types::String.present
      attribute :file_ref, Types::String.present
      attribute :filing_country, CountryCode
      attribute :reference_date, Types::Date.default { Date.today }
    end

    # Scan the same file again, from the start.
    Rescan = Command(:rescan) do
      attribute :reference_date, Types::Date.default { Date.today }
    end

    # Appended by ScanQueue when the expense's scan gets a slot: what Queued
    # enqueued it as. Never sent by a person.
    StartScan = Command(:start_scan)

    # Dispatched by scanning's timer, never by a person.
    TimeOutScan = Command(:time_out_scan)

    # Fill in the form by hand: the scan failed, or rejected a document the
    # person knows is a receipt.
    EnterManually = Command(:enter_manually)

    # The reviewed form. Amounts are integer cents, negative for credit notes.
    SaveExpense = Command(:save_expense) do
      attribute :description, Types::String.present
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Types::Integer.default(0)
      attribute :tax_description, Types::String.nullable
      attribute :currency, CurrencyCode
      attribute :incurred_on, Date
      attribute :supplier_country_code, CountryCode.nullable
      attribute :reverse_charge, Types::Boolean.default(false)
      attribute :payment_reference, Types::String.nullable
    end

    VoidExpense = Command(:void_expense) do
      attribute :reason, Types::String.present
    end

    DiscardDocument = Command(:discard_document)

    # The filed total in the reporting currency, from
    # Expenses::CurrencyConverter: the amount it converted (currency,
    # amount_cents, incurred_on), what it came to in which currency, and at
    # what rate. Only records data: refused once the expense isn't filed,
    # and ignored if the filed amount has changed since.
    RecordConversion = Command(:record_conversion) do
      attribute :currency, CurrencyCode
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, CurrencyCode
      attribute :reporting_cents, Integer
      attribute :rate, Types::Numeric
      attribute :rate_date, Date
    end

    # No conversion of the filed total: why, for a person to read.
    FailConversion = Command(:fail_conversion) do
      attribute :currency, CurrencyCode
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, CurrencyCode
      attribute :reason, Types::String.present
    end

    Category = Types::String.options(CATEGORIES.keys)

    # The model's category for the expense, from Expenses::Categorizer:
    # +probability+ is how likely it thinks its pick (0 to 1), and
    # +description+ what it was told the expense is. Only a suggestion:
    # ignored once a person has chosen one.
    SuggestCategory = Command(:suggest_category) do
      attribute :category, Category
      attribute :probability, Types::Numeric
      attribute :description, Types::String.present
    end

    # No suggestion for +description+: why, for a person to read.
    FailCategorization = Command(:fail_categorization) do
      attribute :description, Types::String.present
      attribute :reason, Types::String.present
    end

    # A person's category: for good, until they choose another.
    ChooseCategory = Command(:choose_category) do
      attribute :category, Category
    end

    # A person's VAT treatment: for good, until they confirm another.
    ConfirmVatTreatment = Command(:confirm_vat_treatment) do
      attribute :treatment, Types::String.options(VAT_TREATMENTS)
    end

    # ---- Events ----

    DocumentUploaded = Event(:document_uploaded) do
      attribute :filename, String
      attribute :content_type, String
      attribute :file_ref, String
      attribute :filing_country, String
    end

    # Every scan starts with one, the first and each rescan.
    ScanRequested = Event(:scan_requested) do
      attribute :reference_date, Date
    end

    # A scan step that went wrong, after its retries. Fatal or not depends
    # on the step: the chart decides where the scan goes next.
    StepFailed = Event(:step_failed) do
      attribute :step, String
      attribute :reason, String
    end

    ExpenseFiled = Event(:expense_filed) do
      attribute :description, String
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Integer
      attribute :tax_description, Types::String.nullable
      attribute :currency, String
      attribute :incurred_on, Date
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean
      attribute :payment_reference, Types::String.nullable
    end

    VatTreatmentConfirmed = Event(:vat_treatment_confirmed) do
      attribute :treatment, String
    end

    ExpenseVoided = Event(:expense_voided) do
      attribute :reason, String
    end

    ConversionRecorded = Event(:conversion_recorded) do
      attribute :currency, String
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, String
      attribute :reporting_cents, Integer
      attribute :rate, Types::Numeric
      attribute :rate_date, Date
    end

    ConversionFailed = Event(:conversion_failed) do
      attribute :currency, String
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, String
      attribute :reason, String
    end

    CategorySuggested = Event(:category_suggested) do
      attribute :category, String
      attribute :probability, Types::Numeric
      attribute :description, String
    end

    CategorizationFailed = Event(:categorization_failed) do
      attribute :description, String
      attribute :reason, String
    end

    CategoryChosen = Event(:category_chosen) do
      attribute :category, String
    end

    # ---- Domain state ----

    # The Document, evolved from the events above and its parts' (the
    # Scanner reads it the same way).
    evolve DocumentProjector

    # ---- The statechart ----

    # Saving the form, the first time or again once filed.
    FILE_EXPENSE = proc do |_doc, cmd|
      event ExpenseFiled, cmd.payload
    end

    # The model's category, whenever it lands. A person's choice is never
    # replaced by a suggestion, and repeats change nothing.
    SUGGEST_CATEGORY = proc do
      command SuggestCategory do |doc, cmd|
        unless doc.category_chosen? || doc.category_suggestion == cmd.payload.to_h.except(:expense_id)
          event CategorySuggested, cmd.payload.to_h.except(:expense_id)
        end
      end

      command FailCategorization do |doc, cmd|
        event CategorizationFailed, cmd.payload.to_h.except(:expense_id) unless doc.category_chosen?
      end
    end

    # Changing their mind, once a step is done. Repeats change nothing.
    CHANGE_REVIEW = proc do
      command ChooseCategory do |doc, cmd|
        event CategoryChosen, cmd.payload unless doc.category == cmd.payload.category
      end

      command ConfirmVatTreatment do |doc, cmd|
        event VatTreatmentConfirmed, cmd.payload unless doc.vat_treatment == cmd.payload.treatment
      end
    end

    RESCAN = proc do
      command Rescan => Queued do |_doc, cmd|
        event ScanRequested, reference_date: cmd.payload.reference_date
      end
    end

    initial do
      command UploadDocument => Queued do |_doc, cmd|
        event DocumentUploaded, cmd.payload.to_h.slice(:filename, :content_type, :file_ref, :filing_country)
        event ScanRequested, reference_date: cmd.payload.reference_date
      end
    end

    # Waiting for a slot to scan in: ScanQueue lets its capacity of expenses scan
    # at once, and appends StartScan when it's this one's turn. Discarded before
    # its turn, it gives its place up. The slot is held through every step of
    # the scan, until it leaves Scanning.
    state Queued do
      entry WorkQueue::Enqueue do |_doc, entered|
        dispatch ScanQueue.enqueue(StartScan, expense_id: entered.payload.expense_id)
      end

      exit WorkQueue::Release | nil do |_doc, left_by|
        next if left_by.payload.entered.include?('scanning')

        dispatch ScanQueue.release(StartScan, expense_id: left_by.payload.expense_id)
      end

      command StartScan => Scanning
      command DiscardDocument => Discarded
    end

    # The progress a person waiting sees is the step scanning is at. The
    # timeout runs from when its slot started it, not from the wait. Leaving
    # it, however, frees the slot.
    state Scanning do
      on_final Scanning::Scanned => Reviewing.history,
               Scanning::NotAnInvoice => Rejected,
               Scanning::Failed => ScanFailed

      exit WorkQueue::Release do |_doc, left_by|
        dispatch ScanQueue.release(StartScan, expense_id: left_by.payload.expense_id)
      end

      after(SCAN_TIMEOUT => TimeOutScan)

      command TimeOutScan => ScanFailed do
        event StepFailed, step: 'scanning', reason: "The scan took longer than #{SCAN_TIMEOUT}"
      end

      command DiscardDocument => Discarded
    end

    # The prefilled form, waiting for a person to choose its category and
    # confirm its VAT treatment, in either order. Entered through its
    # history, so a step done before a rescan stays done.
    state Reviewing do
      region :category do
        initial do
          command ChooseCategory => CategoryConfirmed do |_doc, cmd|
            event CategoryChosen, cmd.payload
          end
        end
        final CategoryConfirmed
      end

      region :vat do
        initial do
          command ConfirmVatTreatment => VatConfirmed do |_doc, cmd|
            event VatTreatmentConfirmed, cmd.payload
          end
        end
        final VatConfirmed
      end

      done Reviewed

      # A step already done, changed while the other waits: its region is
      # final, so the change comes here.
      instance_exec(&CHANGE_REVIEW)
      instance_exec(&SUGGEST_CATEGORY)
      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # Category and VAT treatment confirmed: ready to file.
    state Reviewed do
      command SaveExpense => Filed, &FILE_EXPENSE
      instance_exec(&SUGGEST_CATEGORY)
      instance_exec(&CHANGE_REVIEW)
      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # Not a receipt, says the verification call, with its explanation
    # (doc.verification) to show the person.
    state Rejected do
      command EnterManually => Reviewing.history
      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # A step failed (doc.failure), or the scan timed out.
    state ScanFailed do
      command EnterManually => Reviewing.history
      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # Corrections are saved in place, re-entering filed. The category and
    # VAT treatment stay as confirmed, unless a person changes them.
    state Filed do
      command SaveExpense => Filed, &FILE_EXPENSE
      instance_exec(&SUGGEST_CATEGORY)
      instance_exec(&CHANGE_REVIEW)

      command VoidExpense => Voided do |_doc, cmd|
        event ExpenseVoided, reason: cmd.payload.reason
      end

      # The conversion, for the total as filed now: one of an amount since
      # corrected is dropped (the correction's comes after it), and so is
      # one already recorded.
      command RecordConversion do |doc, cmd|
        converted = cmd.payload.to_h.except(:expense_id)
        if doc.converting?(**converted.slice(:currency, :amount_cents, :incurred_on)) && doc.converted != converted
          event ConversionRecorded, converted
        end
      end

      command FailConversion do |doc, cmd|
        failure = cmd.payload.to_h.except(:expense_id)
        if doc.converting?(**failure.slice(:currency, :amount_cents, :incurred_on)) && doc.conversion_failure != failure
          event ConversionFailed, failure
        end
      end
    end

    final Discarded
    final Voided
  end
end
