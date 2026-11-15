# frozen_string_literal: true

module Expenses
  class Expense
    # Expense's `filed`: the expense is in the books, and its VAT treatment
    # is either the rule's (Document.infer_vat_treatment) or a person's.
    #
    #   inferring_vat ─[confirmed?]────▶ vat_confirmed
    #                 ├[needs review?]─▶ vat_needs_review ─ConfirmVatTreatment─▶ vat_confirmed
    #                 └────────────────▶ vat_inferred ─────ConfirmVatTreatment─▶ vat_confirmed
    #
    # Filing again after an edit re-enters inferring_vat: a confirmed
    # treatment stays confirmed, an inferred one is inferred afresh. An
    # inferred foreign_vat (a foreign supplier that charged VAT, or VAT with
    # no known supplier country) is flagged for review.
    class Filed < Sourced::Machine::Part
      part_of Expense

      InferringVat = State(:inferring_vat)
      VatNeedsReview = State(:vat_needs_review)
      VatInferred = State(:vat_inferred)
      VatConfirmed = State(:vat_confirmed)

      ConfirmVatTreatment = Command(:confirm_vat_treatment) do
        attribute :treatment, Types::String.options(VAT_TREATMENTS)
      end

      VatTreatmentConfirmed = Event(:vat_treatment_confirmed) do
        attribute :treatment, String
      end

      evolve VatTreatmentConfirmed do |doc, evt|
        doc.vat_treatment = evt.payload.treatment
        doc.vat_treatment_confirmed = true
      end

      started InferringVat do
        always VatConfirmed, if: :vat_treatment_confirmed?
        always VatNeedsReview, if: :vat_needs_review?
        always VatInferred
      end

      state VatNeedsReview do
        command ConfirmVatTreatment => VatConfirmed do |_doc, cmd|
          event VatTreatmentConfirmed, treatment: cmd.payload.treatment
        end
      end

      state VatInferred do
        command ConfirmVatTreatment => VatConfirmed do |_doc, cmd|
          event VatTreatmentConfirmed, treatment: cmd.payload.treatment
        end
      end

      # A person may change their mind.
      state VatConfirmed do
        command ConfirmVatTreatment => VatConfirmed do |_doc, cmd|
          event VatTreatmentConfirmed, treatment: cmd.payload.treatment
        end
      end
    end
  end
end
