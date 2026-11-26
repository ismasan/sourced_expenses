# frozen_string_literal: true

module Documents
  # The worker for Document::Scanning. When a document enters one of
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
    partition_by document_id: Types::DocumentID

    dep :llm, :file_store

    # The document each step works on, as the machine sees it, plus
    # Discarded, so a discarded document's step isn't current (see
    # ScannerProjector).
    evolve ScannerProjector

    S = Document::Scanning

    # Entering scanning (an upload, or a rescan) enters preparing too, in
    # scanning's own state event.
    reaction S.to_state_handle => S::CompletePreparation | S::FailPreparation | nil do |doc, entered|
      run_step(entered, S::CompletePreparation, S::FailPreparation) { steps.prepare(doc) }
    end

    reaction S::Extracting => S::CompleteExtraction | S::FailExtraction | nil do |doc, entered|
      run_step(entered, S::CompleteExtraction, S::FailExtraction) { steps.extract(doc) }
    end

    reaction S::Verifying => S::CompleteVerification | S::FailVerification | nil do |doc, entered|
      run_step(entered, S::CompleteVerification, S::FailVerification) { steps.verify(doc) }
    end

    reaction S::RecheckingDate => S::CompleteDateRecheck | S::FailDateRecheck | nil do |doc, entered|
      run_step(entered, S::CompleteDateRecheck, S::FailDateRecheck) { steps.recheck_date(doc) }
    end

    reaction S::Cleaning => S::CompleteCleanup | S::FailCleanup | nil do |doc, entered|
      run_step(entered, S::CompleteCleanup, S::FailCleanup) { steps.clean(doc) }
    end

    private

    # Runs the step in the block and dispatches +complete+ with its result,
    # or +fail+ with why not. Nothing if the document has moved on since
    # +entered+ (done, timed out, discarded, or an old event a new consumer
    # group is catching up on): the step is no one's to do.
    def run_step(entered, complete, fail, &)
      return unless projection.current?(entered)

      document_id = entered.payload.document_id
      command = complete.new(payload: { document_id:, **yield })
      if command.valid?
        dispatch(complete, command.payload.to_h)
      else
        dispatch(fail, document_id:, reason: "The model's answer didn't fit (#{command.errors[:payload].keys.join(', ')})")
      end
    rescue ScanSteps::Error => e
      dispatch(fail, document_id:, reason: e.message)
    end

    def steps = @steps ||= ScanSteps.new(llm:, file_store:)
  end
end
