# frozen_string_literal: true

module UI
  # One document's or expense's messages, commands and events alike, in log
  # order, and its machine evolved from the first +step+ of them: as it is
  # now (+step+ nil), or as it was after any message in its history.
  #
  #   MachineHistory.load(Expenses::Expense, expense_id)
  #   MachineHistory.load(Documents::Document, document_id, step: 3)
  class MachineHistory
    attr_reader :machine_class, :id, :messages, :step

    def self.load(machine_class, id, step: nil)
      # What the machine evolves from, plus the commands it handles: a
      # person's, and its workers'.
      key = machine_class.partition_keys.first
      selector = machine_class.history_selector + Sourced::Selector[*machine_class.handled_commands].by(key)
      new(machine_class:, id:, messages: Sourced.store.read(selector.bind(key => id)).messages, step:)
    end

    def initialize(machine_class:, id:, messages:, step: nil)
      @machine_class = machine_class
      @id = id
      @messages = messages
      @step = step
    end

    def live? = step.nil?

    # Whether anything has happened to it yet.
    def any? = messages.any?

    def current_step = step || messages.size

    # The machine at #current_step. Commands are in the history for the
    # feed; evolving skips them, as the machine only evolves its events.
    def machine
      @machine ||= machine_class.new(machine_class.partition_keys.first => id)
                                .tap { it.evolve(messages.first(current_step)) }
    end
  end
end
