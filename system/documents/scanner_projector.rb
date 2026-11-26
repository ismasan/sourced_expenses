# frozen_string_literal: true

module Documents
  # The document as the Scanner reads it: DocumentProjector's, plus
  # Discarded.
  #
  # A reaction's history includes what came after its trigger, so whether
  # the step is still to do is projection.current?: nothing evolved since.
  # Discarding appends only the state event, so it's evolved here to count.
  # Every other way out of a step appends an event DocumentProjector evolves
  # (the step's result, a StepFailed, a rescan's ScanRequested).
  #
  # A subclass, so Discarded stays off DocumentProjector, which the Document
  # machine evolves with too.
  class ScannerProjector < DocumentProjector
    evolve(Document::Discarded) { |_doc, _evt| nil }
  end
end
