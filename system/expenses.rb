# frozen_string_literal: true

# Expense tracking from scanned receipts and invoices: a photo or PDF goes in,
# several small LLM calls read it, a person reviews the prefilled form and
# files the expense, and a plain rule (not the model) infers its VAT treatment.
# After https://gist.github.com/julik/405662cc3106fe73ae2e46073f483b62
#
#   Expense                 one per uploaded document
#   ├ Expense::Scanning     (part: the OCR pipeline, one LLM call per state)
#   └ Expense::Filed        (part: the filed expense's VAT treatment)
#
# The machines are the spec: every LLM call is a state waiting for its
# worker to report back (Complete…/Fail…), and every decision between calls
# is code, in Document. Nothing here calls a model yet.
module Expenses
  # How an expense's VAT is accounted for. See Document.infer_vat_treatment.
  #
  #   domestic        the filing country's own VAT; reclaimable
  #   import          import VAT on goods; reclaimable. Only ever chosen by a person
  #   reverse_charge  you account for the VAT and reclaim the same amount
  #   foreign_vat     another country's VAT; never reclaimable on this return
  #   no_vat          exempt, outside scope, or not a tax
  VAT_TREATMENTS = %w[domestic import reverse_charge foreign_vat no_vat].freeze

  def self.machines = [Expense]
end
