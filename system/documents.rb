# frozen_string_literal: true

# Reading uploaded receipts and invoices into expenses: a photo or PDF goes
# in, waits its turn to scan (a WorkQueue), several small LLM calls read it,
# and once read it drafts its expense (Expenses::Expense::DraftExpenseFromDocument)
# under its own id. One that couldn't be read, a person can draft by hand.
#
#   Document                one per uploaded file: reads it, drafts its expense
#   └ Document::Scanning    (part: the OCR pipeline, one LLM call per state)
#
# The machine is the spec: every LLM call is a state waiting for its worker
# (Scanner) to report back (Complete…/Fail…), and every decision between
# calls is code, in DocumentState. Nothing here calls a model itself: the
# Scanner's steps (ScanSteps) do, through the `llm` component (Expenses::LLM).
module Documents
  def self.machines = [Document]
end
