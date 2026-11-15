# frozen_string_literal: true

module UI
  # An expense's messages, commands and events alike, in log order, and the
  # Expense machine evolved from the first +step+ of them: the expense as it
  # is now (+step+ nil), or as it was after any message in its history.
  class SubmissionHistory
    attr_reader :expense_id, :messages, :step

    def self.load(expense_id, step: nil)
      # What the machine evolves from, plus the commands it handles: the
      # person's and the scanner's.
      machine = Expenses::Expense
      selector = machine.history_selector + Sourced::Selector[*machine.handled_commands].by(:expense_id)
      new(expense_id:, messages: Sourced.store.read(selector.bind(expense_id:)).messages, step:)
    end

    def initialize(expense_id:, messages:, step: nil)
      @expense_id = expense_id
      @messages = messages
      @step = step
    end

    def live? = step.nil?

    def current_step = step || messages.size

    # The machine at #current_step. Commands are in the history for the
    # feed; evolving skips them, as the machine only evolves its events.
    def expense
      @expense ||= Expenses::Expense.new(expense_id:).tap { it.evolve(messages.first(current_step)) }
    end
  end
end
