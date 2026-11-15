# frozen_string_literal: true

require 'date'

module Expenses
  # One uploaded receipt or invoice, from the upload to a filed expense.
  #
  #   initial ─UploadDocument─▶ scanning ──on_final scanned─────────▶ reviewing ─SaveExpense─▶ filed ⟲ SaveExpense
  #                             (Scanning) ├on_final not_an_invoice─▶ rejected                (Filed)
  #                                        ├on_final failed─────────▶ scan_failed
  #                                        └after 10m: TimeOutScan──▶ scan_failed
  #   rejected, scan_failed ─EnterManually─▶ reviewing
  #   reviewing, rejected, scan_failed ─Rescan─▶ scanning
  #   filed ─VoidExpense─▶ voided;  anything before filed ─DiscardDocument─▶ discarded
  #
  # The model never writes the expense and never decides its tax treatment:
  # the scan prefills a form, and a person files it.
  class Expense < Sourced::Machine
    partition_by expense_id: Types::UUID::V4
    message_prefix 'expenses'

    # How long a scan may take, every LLM call and its retries included,
    # before it's given up on.
    SCAN_TIMEOUT = ENV.fetch('SCAN_TIMEOUT', '10m')

    CurrencyCode = Types::String[/\A[A-Z]{3}\z/]
    CountryCode = Types::String[/\A[A-Z]{2}\z/]

    # ---- States ----

    Reviewing = State(:reviewing)
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
      attribute :expense_id, Types::AutoUUID
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

    # The rule's treatment, until a person confirms one.
    VatTreatmentInferred = Event(:vat_treatment_inferred) do
      attribute :treatment, Types::String.options(VAT_TREATMENTS)
    end

    ExpenseVoided = Event(:expense_voided) do
      attribute :reason, String
    end

    # ---- Domain state ----

    context { Document.new }

    before_evolve do |doc, evt|
      doc.expense_id = evt.payload.expense_id
    end

    evolve DocumentUploaded do |doc, evt|
      doc.filename = evt.payload.filename
      doc.content_type = evt.payload.content_type
      doc.file_ref = evt.payload.file_ref
      doc.filing_country = evt.payload.filing_country
    end

    evolve ScanRequested do |doc, evt|
      doc.start_scan(evt.payload.reference_date)
    end

    evolve StepFailed do |doc, evt|
      doc.failure = { step: evt.payload.step, reason: evt.payload.reason }
    end

    # What was saved is the form from now on.
    evolve ExpenseFiled do |doc, evt|
      doc.filed = evt.payload.to_h.except(:expense_id)
      doc.draft = doc.filed
    end

    evolve VatTreatmentInferred do |doc, evt|
      doc.vat_treatment = evt.payload.treatment
    end

    # ---- The statechart ----

    # Saving the form, the first time or again once filed. A person's VAT
    # choice is for good: saving again doesn't re-infer it.
    FILE_EXPENSE = proc do |doc, cmd|
      expense = cmd.payload.to_h.except(:expense_id)
      event ExpenseFiled, expense
      unless doc.vat_treatment_confirmed?
        event VatTreatmentInferred, treatment: Document.infer_vat_treatment(
          **expense.slice(:reverse_charge, :tax_amount_cents, :supplier_country_code),
          filing_country: doc.filing_country
        )
      end
    end

    initial do
      command UploadDocument => Scanning do |_doc, cmd|
        event DocumentUploaded, cmd.payload.to_h.slice(:filename, :content_type, :file_ref, :filing_country)
        event ScanRequested, reference_date: cmd.payload.reference_date
      end
    end

    # The progress a person waiting sees is the step scanning is at.
    state Scanning do
      on_final Scanning::Scanned => Reviewing,
               Scanning::NotAnInvoice => Rejected,
               Scanning::Failed => ScanFailed

      after(SCAN_TIMEOUT => TimeOutScan)

      command TimeOutScan => ScanFailed do
        event StepFailed, step: 'scanning', reason: "The scan took longer than #{SCAN_TIMEOUT}"
      end

      command DiscardDocument => Discarded
    end

    # The prefilled form, waiting for a person.
    state Reviewing do
      command SaveExpense => Filed, &FILE_EXPENSE

      command Rescan => Scanning do |_doc, cmd|
        event ScanRequested, reference_date: cmd.payload.reference_date
      end

      command DiscardDocument => Discarded
    end

    # Not a receipt, says the verification call, with its explanation
    # (doc.verification) to show the person.
    state Rejected do
      command EnterManually => Reviewing
      command Rescan => Scanning do |_doc, cmd|
        event ScanRequested, reference_date: cmd.payload.reference_date
      end
      command DiscardDocument => Discarded
    end

    # A step failed (doc.failure), or the scan timed out.
    state ScanFailed do
      command EnterManually => Reviewing
      command Rescan => Scanning do |_doc, cmd|
        event ScanRequested, reference_date: cmd.payload.reference_date
      end
      command DiscardDocument => Discarded
    end

    # Corrections are saved in place, re-entering filed: the VAT
    # treatment is inferred again unless a person has confirmed one.
    state Filed do
      command SaveExpense => Filed, &FILE_EXPENSE

      command VoidExpense => Voided do |_doc, cmd|
        event ExpenseVoided, reason: cmd.payload.reason
      end
    end

    final Discarded
    final Voided
  end
end
