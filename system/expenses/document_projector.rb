# frozen_string_literal: true

module Expenses
  # How an expense's Document is evolved from its events: the upload, each
  # scan's results, the form, the filed expense and its USD amount.
  #
  # Shared by whoever needs the document: the Expense machine (its guards and
  # handlers decide on it) and the Scanner (each step works on it). Each
  # adopts it with `evolve DocumentProjector` and gets a subclass of its
  # own, so one adding an evolve block of its own changes nothing for the
  # other.
  #
  # Expense must load first (config/components/sourced.rb registers it before
  # boot.rb eager loads): this class names Expense's events, and Expense
  # adopts it partway through its own body.
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
      doc.forget_stale_usd
    end

    evolve E::VatTreatmentInferred do |doc, evt|
      doc.vat_treatment = evt.payload.treatment
    end

    evolve E::Filed::VatTreatmentConfirmed do |doc, evt|
      doc.vat_treatment = evt.payload.treatment
      doc.vat_treatment_confirmed = true
    end

    evolve E::UsdAmountRecorded do |doc, evt|
      doc.usd = evt.payload.to_h.except(:expense_id)
      doc.usd_failure = nil
    end

    evolve E::UsdConversionFailed do |doc, evt|
      doc.usd_failure = evt.payload.to_h.except(:expense_id)
    end
  end
end
