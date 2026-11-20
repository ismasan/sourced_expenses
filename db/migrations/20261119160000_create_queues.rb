# frozen_string_literal: true

# Queuer: one row per queue, its state (what's queued and what's in flight)
# as JSON, and counts of the same, as integers, for showing a queue's
# progress without parsing the state.
Sequel.migration do
  change do
    create_table(:queues) do
      String :queue_name, primary_key: true
      String :group_id, null: false # the Queuer subclass's consumer group: one owns each queue
      String :state, text: true, null: false # JSON: queued item ids, oldest first; in-flight item ids => started at
      Integer :capacity, null: false # in flight at most, as last decided with
      Integer :queued, null: false, default: 0
      Integer :in_flight, null: false, default: 0
      Integer :enqueued_total, null: false, default: 0
      Integer :started_total, null: false, default: 0
      Integer :released_total, null: false, default: 0 # finished, of those started
      Integer :dropped_total, null: false, default: 0 # released before they started
      Integer :last_position, null: false # the last message applied
      Time :updated_at, null: false

      index :group_id
    end
  end
end
