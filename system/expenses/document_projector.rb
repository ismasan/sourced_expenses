# frozen_string_literal: true

module Expenses
  # How a document's DocumentState is evolved from its events: the upload
  # and each scan's results.
  #
  # Shared by whoever needs the document: the Document machine (its guards
  # and handlers decide on it) and the Scanner (each step works on it). The
  # machine evolves with this class itself (`evolve DocumentProjector`), so
  # an evolve block only one of them needs goes on a subclass: the Scanner's
  # is ScannerProjector.
  class DocumentProjector < Sourced::Projector::Inline
    D = Document
    S = Document::Scanning

    context { DocumentState.new }

    before_evolve do |doc, evt|
      doc.document_id = evt.payload.document_id
    end

    evolve D::DocumentUploaded do |doc, evt|
      doc.filename = evt.payload.filename
      doc.content_type = evt.payload.content_type
      doc.file_ref = evt.payload.file_ref
      doc.filing_country = evt.payload.filing_country
    end

    evolve D::ScanRequested do |doc, evt|
      doc.start_scan(evt.payload.reference_date)
    end

    evolve D::StepFailed do |doc, evt|
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
  end
end
