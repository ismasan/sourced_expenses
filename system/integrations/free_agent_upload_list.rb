# frozen_string_literal: true

module Integrations
  # Each expense FreeAgentUpload created on FreeAgent, by its id there, in
  # the `freeagent_uploads` table: FreeAgentImport leaves those alone, so one
  # uploaded from here never comes back as an expense of its own. Read from
  # the expense's own history (ExpenseUploaded, for FreeAgent). A row stays
  # once there, deleted on FreeAgent or not.
  #
  #   FreeAgentUploadList.external_ids(db) # => Set['123', ...]
  class FreeAgentUploadList < Sourced::Projector::EventSourced
    partition_by expense_id: Types::ExpenseID

    dep :db

    # @return [Set<String>] the FreeAgent ids of every expense created from here
    def self.external_ids(db) = db[:freeagent_uploads].select_map(:external_id).to_set

    def self.on_reset = Sidereal.config['db'][:freeagent_uploads].delete

    # Its first upload's: a correction's is the same expense there.
    context { { expense_id: nil, external_id: nil, uploaded_at: nil } }

    evolve Expenses::Expense::ExpenseUploaded do |row, evt|
      next if row[:external_id] || evt.payload.destination != FreeAgentUpload::DESTINATION

      row.merge!(expense_id: evt.payload.expense_id, external_id: evt.payload.external_id, uploaded_at: evt.created_at)
    end

    sync do |context:, **|
      next unless context[:external_id]

      db[:freeagent_uploads].insert_conflict(target: :external_id).insert(**context)
    end
  end
end
