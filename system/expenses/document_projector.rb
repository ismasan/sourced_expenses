# frozen_string_literal: true

module Expenses
  # How an expense's Document is evolved from its events: the upload, each
  # scan's results, the form, the filed expense, its total in the reporting
  # currency and its category.
  #
  # Shared by whoever needs the document: the Expense machine (its guards and
  # handlers decide on it) and the Scanner (each step works on it). The
  # machine evolves with this class itself (`evolve DocumentProjector`), so
  # an evolve block only one of them needs goes on a subclass: the Scanner's
  # is ScannerProjector.
  class DocumentProjector < Sourced::Projector::Inline
    E = Expense
    S = Expense::Scanning

    context { Document.new }

    before_evolve do |doc, evt|
      doc.expense_id = evt.payload.expense_id
    end

    evolve E::DocumentUploaded do |doc, evt|
      doc.filename = evt.payload.filename
      doc.content_type = evt.payload.content_type
      doc.file_ref = evt.payload.file_ref
      doc.filing_country = evt.payload.filing_country
    end

    evolve E::ScanRequested do |doc, evt|
      doc.start_scan(evt.payload.reference_date)
    end

    evolve E::StepFailed do |doc, evt|
      doc.failure = { step: evt.payload.step, reason: evt.payload.reason }
    end

    # ---- The scan ----

    evolve S::FilePrepared do |doc, evt|
      doc.processed_file_ref = evt.payload.processed_file_ref
    end

    evolve S::ExtractionRecorded do |doc, evt|
      doc.extraction = evt.payload.to_h.except(:expense_id)
    end

    evolve S::DocumentVerified do |doc, evt|
      doc.verification = { is_invoice_or_receipt: evt.payload.is_invoice_or_receipt, explanation: evt.payload.explanation }
    end

    evolve S::DateRechecked do |doc, evt|
      doc.date_recheck = evt.payload.to_h.except(:expense_id)
      doc.correct_date(evt.payload.corrected_date) if evt.payload.corrected_date
    end

    evolve S::TextCleaned do |doc, evt|
      doc.cleanup = { description: evt.payload.description, tax_description: evt.payload.tax_description }
    end

    # The form, prefilled from what the scan read.
    evolve S::Scanned do |doc, _evt|
      doc.draft = doc.attributes
    end

    # ---- Filed ----

    # What was saved is the form from now on.
    evolve E::ExpenseFiled do |doc, evt|
      doc.filed = evt.payload.to_h.except(:expense_id)
      doc.draft = doc.filed
      doc.forget_stale_conversion
    end

    evolve E::VatTreatmentConfirmed do |doc, evt|
      doc.confirmed_vat_treatment = evt.payload.treatment
    end

    evolve E::ConversionRecorded do |doc, evt|
      doc.converted = evt.payload.to_h.except(:expense_id)
      doc.conversion_failure = nil
    end

    evolve E::ConversionFailed do |doc, evt|
      doc.conversion_failure = evt.payload.to_h.except(:expense_id)
    end

    # ---- The category ----

    evolve E::CategorySuggested do |doc, evt|
      doc.category_suggestion = evt.payload.to_h.except(:expense_id)
      doc.category = evt.payload.category
      doc.categorization_failure = nil
    end

    evolve E::CategorizationFailed do |doc, evt|
      doc.categorization_failure = evt.payload.to_h.except(:expense_id)
    end

    evolve E::CategoryChosen do |doc, evt|
      doc.category = evt.payload.category
      doc.category_chosen = true
      doc.categorization_failure = nil
    end
  end
end
