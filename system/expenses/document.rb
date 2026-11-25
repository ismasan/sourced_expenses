# frozen_string_literal: true

require 'date'

module Expenses
  # One uploaded receipt or invoice, from the upload to its expense's draft.
  # Once read, it drafts an Expense with what it read, under its own id, and
  # is attached to it; one it couldn't read, a person can draft by hand. The expense goes its own
  # way from there: this machine only reads documents.
  #
  #   initial ─UploadDocument─▶ queued ─StartScan─▶ scanning ──on_final scanned─────────▶ scanned (drafts its expense)
  #                                                (Scanning) ├on_final not_an_invoice─▶ rejected
  #                                                           ├on_final failed─────────▶ scan_failed
  #                                                           └after 10m: TimeOutScan──▶ scan_failed
  #
  #   rejected, scan_failed ─EnterManually─▶ entered_by_hand (drafts its expense, empty)
  #   scanned, rejected, scan_failed, entered_by_hand ─Rescan─▶ queued
  #   anything ─DiscardDocument─▶ discarded
  #
  # A rescan of a document whose expense is in review replaces the expense's
  # draft once read; of one filed, it changes nothing filed (the Expense
  # decides).
  class Document < Sourced::Machine
    partition_by document_id: Types::DocumentID
    message_prefix 'documents'

    # The queue scans wait in (see Queued), 3 documents scanning at once.
    # Each scan makes up to four model calls, one after another, so this
    # caps the model calls in flight for scanning.
    ScanQueue = WorkQueue.define('scans', capacity: 3)

    # How long a scan may take, every LLM call and its retries included,
    # before it's given up on.
    SCAN_TIMEOUT = ENV.fetch('SCAN_TIMEOUT', '10m')

    CountryCode = Types::String[/\A[A-Z]{2}\z/]

    # ---- States ----

    Queued = State(:queued)
    Scanned = State(:scanned)
    Rejected = State(:rejected)
    ScanFailed = State(:scan_failed)
    EnteredByHand = State(:entered_by_hand)
    Discarded = State(:discarded)

    # ---- Commands ----

    # +file_ref+ is wherever the upload was stored; +filing_country+, the
    # country of the company whose books this is in. +reference_date+ is
    # "today" for the scan: the prompts resolve ambiguous dates towards it,
    # and passing it in keeps decisions deterministic.
    UploadDocument = Command(:upload_document) do
      attribute :document_id, Types::DocumentID
      attribute :filename, Types::String.present
      attribute :content_type, Types::String.present
      attribute :file_ref, Types::String.present
      attribute :filing_country, CountryCode
      attribute :reference_date, Types::Date.default { Date.today }
    end

    # Scan the same file again, from the start.
    Rescan = Command(:rescan) do
      attribute :reference_date, Types::Date.default { Date.today }
    end

    # Appended by ScanQueue when the document's scan gets a slot: what
    # Queued enqueued it as. Never sent by a person.
    StartScan = Command(:start_scan)

    # Dispatched by scanning's timer, never by a person.
    TimeOutScan = Command(:time_out_scan)

    # Draft its expense by hand: the scan failed, or rejected a document the
    # person knows is a receipt.
    EnterManually = Command(:enter_manually)

    DiscardDocument = Command(:discard_document)

    # ---- Events ----

    DocumentUploaded = Event(:document_uploaded) do
      attribute :filename, String
      attribute :content_type, String
      attribute :file_ref, String
      attribute :filing_country, String
    end

    # Every scan starts with one, the first and each rescan.
    ScanRequested = Event(:scan_requested) do
      attribute :reference_date, Date
    end

    # A scan step that went wrong, after its retries. Fatal or not depends
    # on the step: the chart decides where the scan goes next.
    StepFailed = Event(:step_failed) do
      attribute :step, String
      attribute :reason, String
    end

    # ---- Domain state ----

    # The DocumentState, evolved from the events above and its part's (the
    # Scanner reads it the same way).
    evolve DocumentProjector

    # ---- The statechart ----

    RESCAN = proc do
      command Rescan => Queued do |_doc, cmd|
        event ScanRequested, cmd.payload
      end
    end

    initial do
      command UploadDocument => Queued do |_doc, cmd|
        event DocumentUploaded, cmd.payload
        event ScanRequested, cmd.payload
      end
    end

    # Waiting for a slot to scan in: ScanQueue lets its capacity of
    # documents scan at once, and appends StartScan when it's this one's
    # turn. Discarded before its turn, it gives its place up. The slot is
    # held through every step of the scan, until it leaves Scanning.
    state Queued do
      entry WorkQueue::Enqueue do |_doc, entered|
        dispatch ScanQueue.enqueue(StartScan, document_id: entered.payload.document_id)
      end

      exit WorkQueue::Release | nil do |_doc, left_by|
        next if left_by.payload.entered.include?('scanning')

        dispatch ScanQueue.release(StartScan, document_id: left_by.payload.document_id)
      end

      command StartScan => Scanning
      command DiscardDocument => Discarded
    end

    # The progress a person waiting sees is the step scanning is at. The
    # timeout runs from when its slot started it, not from the wait. Leaving
    # it, however, frees the slot.
    state Scanning do
      on_final Scanning::Scanned => Scanned,
               Scanning::NotAnInvoice => Rejected,
               Scanning::Failed => ScanFailed

      exit WorkQueue::Release do |_doc, left_by|
        dispatch ScanQueue.release(StartScan, document_id: left_by.payload.document_id)
      end

      after(SCAN_TIMEOUT => TimeOutScan)

      command TimeOutScan => ScanFailed do
        event StepFailed, step: 'scanning', reason: "The scan took longer than #{SCAN_TIMEOUT}"
      end

      command DiscardDocument => Discarded
    end

    # Read: its expense is drafted with what was read, under the document's
    # id, the first time or again after a rescan.
    state Scanned do
      entry Expense::DraftExpenseFromDocument do |doc, _entered|
        dispatch Expense::DraftExpenseFromDocument, doc.prefill
      end

      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # Not a receipt, says the verification call, with its explanation
    # (doc.verification) to show the person.
    state Rejected do
      command EnterManually => EnteredByHand
      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # A step failed (doc.failure), or the scan timed out.
    state ScanFailed do
      command EnterManually => EnteredByHand
      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    # Unread, its expense drafted empty for a person to fill in.
    state EnteredByHand do
      entry Expense::DraftExpenseFromDocument do |doc, _entered|
        dispatch Expense::DraftExpenseFromDocument, doc.prefill(read: false)
      end

      instance_exec(&RESCAN)
      command DiscardDocument => Discarded
    end

    final Discarded
  end
end
