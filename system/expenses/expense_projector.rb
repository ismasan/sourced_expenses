# frozen_string_literal: true

module Expenses
  # How an expense's ExpenseState is evolved from its events: its document,
  # its figures (drafted or entered), the filed expense, its total in the reporting currency, its category and its
  # VAT treatment. The Expense machine evolves with it (`evolve
  # ExpenseProjector`).
  class ExpenseProjector < Sourced::Projector::Inline
    E = Expense

    context { ExpenseState.new }

    before_evolve do |doc, evt|
      doc.expense_id = evt.payload.expense_id
    end

    # A draft, the first or its document read again.
    DRAFT = proc { |doc, evt| doc.draft!(evt.payload.to_h.except(:expense_id)) }
    evolve E::ExpenseDrafted, &DRAFT
    evolve E::ExpenseRedrafted, &DRAFT

    evolve E::ExpenseEntered do |doc, evt|
      doc.enter!(evt.payload.to_h.except(:expense_id))
    end

    evolve E::DocumentAttached do |doc, evt|
      doc.document_id = evt.payload.document_id
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
