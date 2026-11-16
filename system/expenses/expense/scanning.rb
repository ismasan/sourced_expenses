# frozen_string_literal: true

module Expenses
  class Expense
    # Expense's `scanning`: the OCR pipeline, one LLM call per waiting state,
    # each in its own chat with its own schema. A worker does each step when
    # its state is entered and reports back with the step's Complete… or
    # Fail… command. The decisions in between are code (Document), taken as
    # transient states that move on in the same decision.
    #
    #   preparing ─CompletePreparation─▶ extracting ─CompleteExtraction─▶ checking_extraction
    #
    #   checking_extraction ─[implausible?]─▶ verifying ─CompleteVerification [receipt]─▶ checking_date
    #                       └───────────────────────────────────────────────────────────▶ checking_date
    #                                         verifying ─CompleteVerification [not one]─▶ not_an_invoice (final)
    #
    #   checking_date ─[date_suspect?]─▶ rechecking_date ─CompleteDateRecheck─▶ cleaning
    #                 │                                  └FailDateRecheck─────▶ cleaning (first reading stands)
    #                 └─────────────────────────────────────────────────────────▶ cleaning
    #
    #   cleaning ─CompleteCleanup─▶ scanned (final)
    #            └FailCleanup────▶ scanned (original text kept)
    #
    #   preparing, extracting, verifying ─Fail…─▶ failed (final)
    #
    # The workers' steps:
    #
    #   preparing        shrink an image over 500 KB, never send the original. PDFs as they are
    #   extracting       SYSTEM_PROMPT + USER_PROMPT_TEMPLATE, EXTRACTION_SCHEMA
    #   verifying        DOCUMENT_VERIFICATION_PROMPT, told doc.extraction_errors
    #   rechecking_date  DATE_RECHECK_PROMPT, told the first reading is suspect
    #   cleaning         CLEANUP_PROMPT: mojibake in description and tax_description
    class Scanning < Sourced::Machine::Part
      part_of Expense

      # ---- States ----

      Preparing = State(:preparing)
      Extracting = State(:extracting)
      CheckingExtraction = State(:checking_extraction)
      Verifying = State(:verifying)
      CheckingDate = State(:checking_date)
      RecheckingDate = State(:rechecking_date)
      Cleaning = State(:cleaning)
      Scanned = State(:scanned)
      NotAnInvoice = State(:not_an_invoice)
      Failed = State(:failed)

      # The extraction as the model returned it, EXTRACTION_SCHEMA's fields.
      # Everything is nullable (a missing key is nil) and amounts are any
      # number: refusing a bad extraction at the command would skip the
      # plausibility check, whose job it is.
      EXTRACTION = {
        document_type: Types::String.nullable,       # invoice | credit_note
        description: Types::String.nullable,         # "Vendor - what was bought"
        total_amount: Types::Numeric.nullable,       # gross; negative for credit notes
        net_amount: Types::Numeric.nullable,
        tax_amount: Types::Numeric.nullable,
        tax_description: Types::String.nullable,     # "BTW 21%"
        currency: Types::String.nullable,            # ISO 4217
        date_as_printed: Types::String.nullable,     # verbatim, before it's interpreted
        date: Types::String.nullable,                # ISO 8601
        datetime: Types::String.nullable,
        vendor_name: Types::String.nullable,
        confidence: Types::String.nullable,          # high | medium | low
        notes: Types::String.nullable,
        document_language: Types::String.nullable,   # ISO 639-1
        supplier_country_code: Types::String.nullable,
        reverse_charge: Types::Boolean.nullable,
        payment_reference: Types::String.nullable
      }.transform_values { it.default(nil) }.freeze

      DateCandidate = Types::Hash[
        date: String,
        reading: String,
        in_the_future: Types::Boolean
      ]

      # ---- Commands: the workers reporting back ----

      CompletePreparation = Command(:complete_preparation) do
        attribute :processed_file_ref, Types::String.present
        attribute :downsized, Types::Boolean.default(false)
      end

      CompleteExtraction = Command(:complete_extraction) do
        EXTRACTION.each { |name, type| attribute name, type }
      end

      CompleteVerification = Command(:complete_verification) do
        attribute :is_invoice_or_receipt, Types::Boolean
        attribute :explanation, String
      end

      CompleteDateRecheck = Command(:complete_date_recheck) do
        attribute :date_as_printed, String
        attribute :candidates, Types::Array[DateCandidate]
        attribute :date, String
        attribute :reasoning, String
      end

      CompleteCleanup = Command(:complete_cleanup) do
        attribute :description, String
        attribute :tax_description, Types::String.nullable
      end

      FailPreparation = Command(:fail_preparation) { attribute :reason, String }
      FailExtraction = Command(:fail_extraction) { attribute :reason, String }
      FailVerification = Command(:fail_verification) { attribute :reason, String }
      FailDateRecheck = Command(:fail_date_recheck) { attribute :reason, String }
      FailCleanup = Command(:fail_cleanup) { attribute :reason, String }

      # ---- Events ----

      FilePrepared = Event(:file_prepared) do
        attribute :processed_file_ref, String
        attribute :downsized, Types::Boolean
      end

      ExtractionRecorded = Event(:extraction_recorded) do
        EXTRACTION.each { |name, type| attribute name, type }
      end

      DocumentVerified = Event(:document_verified) do
        attribute :is_invoice_or_receipt, Types::Boolean
        attribute :explanation, String
      end

      # Every recheck, applied or not: +corrected_date+ (ISO 8601) is the
      # date that replaced the first reading, if it did.
      DateRechecked = Event(:date_rechecked) do
        attribute :date_as_printed, String
        attribute :candidates, Types::Array[DateCandidate]
        attribute :date, String
        attribute :reasoning, String
        attribute :previous_date, Types::String.nullable
        attribute :corrected_date, Types::String.nullable
      end

      TextCleaned = Event(:text_cleaned) do
        attribute :description, String
        attribute :tax_description, Types::String.nullable
      end

      # Evolved on the Document by DocumentProjector.

      # ---- The statechart ----

      started Preparing do
        command CompletePreparation => Extracting do |_doc, cmd|
          event FilePrepared, cmd.payload.to_h.slice(:processed_file_ref, :downsized)
        end

        command FailPreparation => Failed do |_doc, cmd|
          event StepFailed, step: 'preparing', reason: cmd.payload.reason
        end
      end

      state Extracting do
        command CompleteExtraction => CheckingExtraction do |_doc, cmd|
          event ExtractionRecorded, cmd.payload.to_h.slice(*EXTRACTION.keys)
        end

        command FailExtraction => Failed do |_doc, cmd|
          event StepFailed, step: 'extracting', reason: cmd.payload.reason
        end
      end

      # Missing essentials, odd amounts or low confidence: is this a
      # receipt at all?
      state CheckingExtraction do
        always Verifying, if: :implausible?
        always CheckingDate
      end

      # A receipt goes on, and the person corrects the form; anything else
      # is rejected with the model's explanation.
      state Verifying do
        command CompleteVerification => CheckingDate | NotAnInvoice do |_doc, cmd|
          event DocumentVerified, cmd.payload.to_h.slice(:is_invoice_or_receipt, :explanation)
          to(cmd.payload.is_invoice_or_receipt ? CheckingDate : NotAnInvoice)
        end

        command FailVerification => Failed do |_doc, cmd|
          event StepFailed, step: 'verifying', reason: cmd.payload.reason
        end
      end

      # An all-numeric date after the reference date, or more than 60 days
      # before it.
      state CheckingDate do
        always RecheckingDate, if: :date_suspect?
        always Cleaning
      end

      # The first reading stands unless the recheck finds a better one.
      state RecheckingDate do
        command CompleteDateRecheck => Cleaning do |doc, cmd|
          event DateRechecked,
                **cmd.payload.to_h.slice(:date_as_printed, :candidates, :date, :reasoning),
                previous_date: doc.extracted_date&.iso8601,
                corrected_date: doc.date_correction(cmd.payload.date)&.iso8601
        end

        command FailDateRecheck => Cleaning do |_doc, cmd|
          event StepFailed, step: 'rechecking_date', reason: cmd.payload.reason
        end
      end

      # The original text stands if the cleanup fails.
      state Cleaning do
        command CompleteCleanup => Scanned do |_doc, cmd|
          event TextCleaned, cmd.payload.to_h.slice(:description, :tax_description)
        end

        command FailCleanup => Scanned do |_doc, cmd|
          event StepFailed, step: 'cleaning', reason: cmd.payload.reason
        end
      end

      final Scanned
      final NotAnInvoice
      final Failed
    end
  end
end
