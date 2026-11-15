# frozen_string_literal: true

module Expenses
  # The worker for Expense::Scanning. When an expense enters one of
  # scanning's waiting states, the scanner does that state's step
  # (ScanSteps) and reports back with the step's Complete… command, or its
  # Fail… with a reason a person can read.
  #
  # A consumer group of its own, so a model call that takes seconds never
  # holds up the machine or the read model. What a step can expect to go
  # wrong (the model, the image, a missing file: ScanSteps::Error) becomes
  # the step's Fail…, and so does an answer that doesn't fit the command.
  # Anything else is a bug and raises, which stops the scanner's group.
  class Scanner < Sourced::Decider
    partition_by expense_id: Types::UUID::V4

    dep :llm, :file_store

    S = Expense::Scanning

    Step = ::Data.define(:state, :run, :complete, :fail)

    # By the path the machine enters. The first, preparing, comes in on
    # scanning's own state event: entering scanning enters it too.
    STEPS = {
      'scanning.preparing' => Step.new(S::Preparing, :prepare, S::CompletePreparation, S::FailPreparation),
      'scanning.extracting' => Step.new(S::Extracting, :extract, S::CompleteExtraction, S::FailExtraction),
      'scanning.verifying' => Step.new(S::Verifying, :verify, S::CompleteVerification, S::FailVerification),
      'scanning.rechecking_date' => Step.new(S::RecheckingDate, :recheck_date, S::CompleteDateRecheck, S::FailDateRecheck),
      'scanning.cleaning' => Step.new(S::Cleaning, :clean, S::CompleteCleanup, S::FailCleanup)
    }.freeze

    OUTPUTS = STEPS.values.flat_map { [it.complete, it.fail] }.reduce(:|)

    # The state events that enter a step: each step's own, plus scanning's
    # (Scanning.to_state_handle), since entering scanning on an upload or a
    # rescan appends that one event, with 'scanning.preparing' in its entered
    # paths. Not every transition: the reaction only has work on these.
    INPUTS = [S.to_state_handle, *STEPS.values.map(&:state)].reduce(:|)

    reaction INPUTS => OUTPUTS | nil do |_context, entered|
      path = entered.payload.entered.find { STEPS.key?(it) }
      next unless path

      step = STEPS.fetch(path)
      expense_id = entered.payload.expense_id
      expense, = Sourced.load(Expense, expense_id:)
      # Moved on since (timed out, discarded, or this is an old event a new
      # consumer group is catching up on): the step is no one's to do.
      next unless expense.machine.in?(step.state)

      result = begin
        { complete: steps.public_send(step.run, expense.context) }
      rescue ScanSteps::Error => e
        { fail: e.message }
      end

      if result[:complete]
        command = step.complete.new(payload: { expense_id:, **result[:complete] })
        if command.valid?
          dispatch(step.complete, command.payload.to_h)
        else
          dispatch(step.fail, expense_id:, reason: "The model's answer didn't fit (#{command.errors[:payload].keys.join(', ')})")
        end
      else
        dispatch(step.fail, expense_id:, reason: result[:fail])
      end
    end

    private def steps = @steps ||= ScanSteps.new(llm:, file_store:)
  end
end
