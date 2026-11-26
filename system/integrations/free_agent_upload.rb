# frozen_string_literal: true

module Integrations
  # Uploads an expense filed here to FreeAgent, keeps it up to date as it's
  # corrected here, and deletes it there when it's voided here: a machine
  # per expense, so one expense's filings are taken in turn. How each went
  # is the expense's own history: its entries tell the expense
  # (Expense::RecordUpload, RecordUploadFailure, RecordUploadDeletion), and
  # it moves on what the expense records (ExpenseUploaded,
  # ExpenseUploadFailed, ExpenseUploadDeleted, for FreeAgent).
  #
  #   initial, uploaded, failed ─on ExpenseFiled [uploads on]─▶ uploading
  #   uploading ─on ExpenseUploaded─▶ uploaded, or uploading again (filed
  #             │                     again meanwhile), or deleting (voided meanwhile)
  #             ├on ExpenseUploadFailed─▶ failed
  #             └after 5m: TimeOutUpload─▶ failed (recording why on the expense)
  #   failed ─RetryUpload─▶ uploading
  #   uploaded, failed (once there) ─on ExpenseVoided─▶ deleting
  #   deleting ─on ExpenseUploadDeleted─▶ deleted
  #            ├on ExpenseUploadFailed─▶ not_deleted ─RetryDelete─▶ deleting
  #            └after 5m: TimeOutDelete─▶ not_deleted
  #
  # Uploads only expenses filed while uploads are on
  # (FreeAgentSettings.uploads_on_since) and FreeAgent is connected: one
  # filed before they were turned on, or while they're off, is left alone,
  # recording nothing. Never one imported from FreeAgent: that one is
  # FreeAgent's (its corrections are made there).
  #
  # Entering uploading creates the expense on FreeAgent the first time
  # (Client#create_expense) and updates it from then on, with what's filed
  # now (FreeAgent::UploadMapping). One FreeAgent couldn't take says why,
  # and so does one it couldn't be reached for, which may have been created
  # there all the same (+unsure+): never tried again by itself, for that
  # reason. A person retries it from its page.
  #
  # Its document's file goes with it (UploadMapping.attachment), until one
  # upload has taken it: FreeAgent keeps it through later updates. One that
  # can't go is uploaded without it, the expense recording why.
  #
  # The FreeAgent expenses it creates are FreeAgentUploadList's, for the
  # importer to leave alone.
  class FreeAgentUpload < Sourced::Machine
    extend Sidereal::Deps

    partition_by expense_id: Types::ExpenseID
    message_prefix 'freeagent_uploads'

    dep :freeagent, :file_store

    E = Expenses::Expense

    # Its name, as the expense records where it was uploaded.
    DESTINATION = FreeAgent::ExpenseMapping::SOURCE

    # How long a call to FreeAgent may take, before it's given up on.
    TIMEOUT = '5m'
    TIMED_OUT = "FreeAgent took longer than #{TIMEOUT} to answer: check it there before trying again".freeze

    # ---- States ----

    Uploading = State(:uploading)
    Uploaded = State(:uploaded)
    Failed = State(:failed)
    Deleting = State(:deleting)
    Deleted = State(:deleted)
    NotDeleted = State(:not_deleted)

    # ---- Commands: its own timeouts, and a person ----

    TimeOutUpload = Command(:time_out_upload)
    RetryUpload = Command(:retry_upload)
    TimeOutDelete = Command(:time_out_delete)
    RetryDelete = Command(:retry_delete)

    # ---- Its state ----

    # +imported+: from FreeAgent, so never uploaded. +latest_filing+, the
    # id of its latest ExpenseFiled, and +uploading_filing+ the one being
    # uploaded: filed again meanwhile, it's uploaded again. +external_id+
    # and +external_url+ (its page), once it's on FreeAgent; +attached+, the
    # name of its document's file once that's there too, or
    # +attachment_problem+, why it isn't. +settled+, the
    # position of the last outcome recorded, so an entry with one after it
    # has nothing left to do.
    context do
      { imported: false, latest_filing: nil, uploading_filing: nil, voided: false, external_id: nil,
        external_url: nil, attached: nil, attachment_problem: nil, failure: nil, settled: nil }
    end

    evolve E::ExpenseImported do |run, evt|
      run[:imported] = true if evt.payload.source == DESTINATION
    end

    evolve(E::ExpenseFiled) { |run, evt| run[:latest_filing] = evt.id }
    evolve(E::ExpenseVoided) { |run, _evt| run[:voided] = true }

    evolve Uploading do |run, _evt|
      run[:uploading_filing] = run[:latest_filing]
    end

    SETTLED = proc { |run, evt| run[:settled] = evt.position if evt.respond_to?(:position) && evt.position }

    evolve E::ExpenseUploaded do |run, evt|
      next unless evt.payload.destination == DESTINATION

      run.merge!(external_id: evt.payload.external_id, external_url: evt.payload.external_url, failure: nil)
      run[:attached] ||= evt.payload.attachment
      run[:attachment_problem] = run[:attached] ? nil : evt.payload.attachment_problem
      instance_exec(run, evt, &SETTLED)
    end

    evolve E::ExpenseUploadFailed do |run, evt|
      next unless evt.payload.destination == DESTINATION

      run[:failure] = { reason: evt.payload.reason, unsure: evt.payload.unsure, at: evt.created_at }
      instance_exec(run, evt, &SETTLED)
    end

    evolve E::ExpenseUploadDeleted do |run, evt|
      next unless evt.payload.destination == DESTINATION

      run[:failure] = nil
      instance_exec(run, evt, &SETTLED)
    end

    # ---- The statechart ----

    # A filing to upload: uploads on since before it was filed, and
    # FreeAgent connected. Never one imported from FreeAgent.
    FILED = proc do
      on E::ExpenseFiled => Uploading | nil do |run, filed|
        next if run[:imported]
        next unless uploads_on_for?(filed)

        to Uploading
      end
    end

    # Voided here, once it's on FreeAgent: deleted there too.
    VOIDED = proc do
      on E::ExpenseVoided => Deleting | nil do |run, _voided|
        next unless run[:external_id] && freeagent.connected?

        to Deleting
      end
    end

    # Entered on a timeout: why, recorded on the expense. Whether it was
    # done there isn't known for one that wasn't there yet.
    TIMED_OUT_ENTRY = proc do |timeout|
      entry E::RecordUploadFailure | nil do |run, entered|
        next unless entered.payload.trigger == timeout.type
        next if settled_since?(run, entered)

        dispatch E::RecordUploadFailure, expense_id: entered.payload.expense_id, destination: DESTINATION,
                                         reason: TIMED_OUT, unsure: run[:external_id].nil?
      end
    end

    initial(&FILED)

    state Uploading do
      entry E::RecordUpload | E::RecordUploadFailure | nil do |run, entered|
        next if settled_since?(run, entered)

        expense_id = entered.payload.expense_id
        begin
          doc = Sourced.load(E, expense_id:).first.context
          attributes = attributes_for(doc)
          attachment, attachment_problem = attachment_for(doc) unless run[:attached]
          attributes[:attachment] = attachment if attachment
          id = run[:external_id]
          if id
            freeagent.update_expense("/expenses/#{id}", attributes)
          else
            id = freeagent.create_expense(attributes).split('/').last
          end
          dispatch E::RecordUpload, expense_id:, destination: DESTINATION, external_id: id,
                                    external_url: run[:external_url] || page_url(id),
                                    attachment: attachment&.fetch(:file_name), attachment_problem:
        rescue FreeAgent::Unreachable => e
          dispatch E::RecordUploadFailure, expense_id:, destination: DESTINATION, reason: unreachable_reason(e, run),
                                           unsure: run[:external_id].nil?
        rescue FreeAgent::Error => e
          dispatch E::RecordUploadFailure, expense_id:, destination: DESTINATION, reason: e.message
        end
      end

      after(TIMEOUT => TimeOutUpload)

      on E::ExpenseUploaded => Uploaded | Uploading | Deleting | nil do |run, uploaded|
        next unless uploaded.payload.destination == DESTINATION

        if run[:voided] then to Deleting
        elsif run[:latest_filing] != run[:uploading_filing] then to Uploading
        else to Uploaded
        end
      end

      on E::ExpenseUploadFailed => Failed | nil do |_run, failed|
        next unless failed.payload.destination == DESTINATION

        to Failed
      end

      command TimeOutUpload => Failed
    end

    state Uploaded do
      instance_exec(&FILED)
      instance_exec(&VOIDED)
    end

    state Failed do
      instance_exec(TimeOutUpload, &TIMED_OUT_ENTRY)
      instance_exec(&FILED)
      instance_exec(&VOIDED)
      command RetryUpload => Uploading
    end

    state Deleting do
      entry E::RecordUploadDeletion | E::RecordUploadFailure | nil do |run, entered|
        next if settled_since?(run, entered)

        expense_id = entered.payload.expense_id
        begin
          freeagent.delete_expense("/expenses/#{run[:external_id]}")
          dispatch E::RecordUploadDeletion, expense_id:, destination: DESTINATION
        rescue FreeAgent::Error => e
          dispatch E::RecordUploadFailure, expense_id:, destination: DESTINATION, reason: e.message
        end
      end

      after(TIMEOUT => TimeOutDelete)

      on E::ExpenseUploadDeleted => Deleted | nil do |_run, deleted|
        next unless deleted.payload.destination == DESTINATION

        to Deleted
      end

      on E::ExpenseUploadFailed => NotDeleted | nil do |_run, failed|
        next unless failed.payload.destination == DESTINATION

        to NotDeleted
      end

      command TimeOutDelete => NotDeleted
    end

    state NotDeleted do
      instance_exec(TimeOutDelete, &TIMED_OUT_ENTRY)
      command RetryDelete => Deleting
    end

    final Deleted

    private

    # What's filed now, as FreeAgent's attributes. One that can't be
    # mapped, whatever the reason, is refused before anything is written.
    # @raise [FreeAgent::Error]
    def attributes_for(doc)
      FreeAgent::UploadMapping.attributes(doc, user: freeagent.current_user_url, categories: freeagent.categories,
                                               company_currency: freeagent.company_currency)
    rescue FreeAgent::Error
      raise
    rescue StandardError => e
      raise FreeAgent::UploadMapping::Refused, "It couldn’t be put the way FreeAgent takes it (#{e.class})"
    end

    # Its document's file as FreeAgent's attachment, or why it can't be
    # (nil for both, for an expense without one).
    # @return [Array(Hash, nil), Array(nil, String), nil]
    def attachment_for(doc)
      return unless doc.document_id

      document = Sourced.load(Documents::Document, document_id: doc.document_id).first.context
      return unless document.file_ref

      [FreeAgent::UploadMapping.attachment(document, file_store:), nil]
    rescue FreeAgent::UploadMapping::NoAttachment => e
      [nil, e.message]
    rescue StandardError => e
      [nil, "Its file couldn’t be read (#{e.class}): attach it on FreeAgent"]
    end

    # Its page on FreeAgent, or nil: a link isn't worth failing for.
    def page_url(id)
      FreeAgent::ExpenseMapping.page_url(freeagent.web_url, freeagent.current_user_url, id)
    rescue FreeAgent::Error
      nil
    end

    # Whether uploads were on, FreeAgent connected, when +filed+ was filed.
    def uploads_on_for?(filed)
      since = FreeAgentSettings.uploads_on_since
      !since.nil? && filed.created_at >= since && freeagent.connected?
    end

    # An outcome recorded after +entered+ (an upload done or failed, a
    # deletion): the entry has been dealt with, as a group catching up
    # finds it.
    def settled_since?(run, entered)
      run[:settled] && entered.respond_to?(:position) && entered.position && run[:settled] > entered.position
    end

    def unreachable_reason(error, run)
      return error.message if run[:external_id]

      "#{error.message}: it may have been created there all the same, so check FreeAgent before trying again"
    end
  end
end
