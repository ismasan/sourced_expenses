# frozen_string_literal: true

require 'json'

# A capped work queue, as a Sourced reactor: at most +capacity+ items in
# flight, the rest waiting their turn, oldest first. Whoever has work sends
# the queue's Enqueue, and its Release once the work is done or abandoned;
# the queue dispatches each item's start command when it gets a slot.
#
# A subclass is one kind of queue: it names its commands' type prefix and
# its queue, says how many may be in flight, and what starting an item
# dispatches.
#
#   class Expenses::ScanQueue < Queuer
#     queue 'expenses.scan_queue', name: 'scans'
#
#     def capacity = 3
#     def start(item_id) = Expenses::Expense::StartScan.new(payload: { expense_id: item_id })
#   end
#
#   dispatch Expenses::ScanQueue::Enqueue, item_id: expense_id # queue_name defaults to 'scans'
#
# Each queue (queue_name) is one partition, so its messages are applied one
# claim at a time. It reads no history: its state is a row in the `queues`
# table, loaded at each claim and saved in the claim's own transaction (a
# +sync+ action), so the row, the start commands and the ack commit
# together or not at all. The row's integer columns count what the JSON
# state holds, for showing a queue without parsing it.
#
# Releasing an item that isn't queued or in flight changes nothing, and
# neither does enqueueing one that is. A start command can reach work that
# has moved on (ex. discarded while its start was on its way): it's for the
# receiver to refuse it, and the Release that follows frees its slot.
#
# Once a claim has committed, the queue publishes its Changed signal (as a
# projector its Projected), for pages showing it to follow: they read it
# with .status.
#
#   on Expenses::ScanQueue::Changed do |_evt| ... Expenses::ScanQueue.status ... end
class Queuer
  extend Sidereal::Deps
  dep :db

  TABLE = :queues

  # Raised when the row changed since it was loaded: another claim of the
  # same queue (ex. one the stale-claim reaper handed on) saved first. It
  # rolls the claim back, to be retried.
  Conflict = Class.new(StandardError)

  # A queue at a glance, from its row's counts: what .status returns.
  Status = Data.define(:queue_name, :capacity, :queued, :in_flight, :enqueued_total, :started_total,
                       :released_total, :dropped_total, :updated_at) do
    # @return [Integer] slots free now
    def free = [capacity - in_flight, 0].max

    # @return [Boolean] whether nothing is queued or in flight
    def idle? = queued.zero? && in_flight.zero?
  end

  COUNTS = %i[queued in_flight enqueued_total started_total released_total dropped_total].freeze

  class << self
    # Declare the queue: its commands, typed under +prefix+ (also the consumer
    # group), and +name+, the queue its commands go to unless they say
    # another.
    #
    # @param prefix [String] ex. 'expenses.scan_queue'
    # @param name [String] the default queue_name
    def queue(prefix, name:)
      @group_id = prefix
      @queue_name = name
      const_set(:Enqueue, Sourced::Command.define("#{prefix}.enqueue") do
        attribute :queue_name, Types::String.default(name)
        attribute :item_id, Types::String.present
      end)
      const_set(:Release, Sourced::Command.define("#{prefix}.release") do
        attribute :queue_name, Types::String.default(name)
        attribute :item_id, Types::String.present
      end)
      # Published, not stored: the queue changed (see #handle).
      const_set(:Changed, Sourced::Event.define("#{prefix}.changed") do
        attribute :queue_name, Types::String
      end)
    end

    attr_reader :queue_name

    # The queue as its row last saved it, with the capacity it has now (the
    # row's is the one it last decided with). An empty queue before its
    # first message.
    #
    # @param name [String] the queue, the default one unless given
    # @return [Status]
    def status(name = queue_name, db: Sidereal.config['db'])
      row = db[TABLE].where(queue_name: name, group_id:).first
      counts = COUNTS.to_h { [it, row ? row[it] : 0] }
      Status.new(queue_name: name, capacity: new.capacity, **counts, updated_at: row&.dig(:updated_at))
    end

    # Sourced reactor protocol.
    def group_id = @group_id

    # None for Queuer itself, which only defines queues: so the system/ scan
    # registers its subclasses, not it.
    # @return [Array<Class>]
    def handled_messages = const_defined?(:Enqueue, false) ? [self::Enqueue, self::Release] : []

    # Sourced reactor protocol: its commands, one partition per queue.
    def claim_selector = Sourced::Selector[*handled_messages].by(:queue_name)

    # Sourced reactor protocol.
    def handle_claim(claim) = new.handle(claim)

    # Resetting the consumer group replays every Enqueue and Release, from an
    # empty queue.
    def on_reset = Sidereal.config['db'][TABLE].where(group_id:).delete
  end

  # @return [Integer] how many items may be in flight
  def capacity = raise(NotImplementedError, "#{self.class} must define #capacity")

  # @param item_id [String]
  # @return [Sourced::Message] the command that starts +item_id+'s work
  def start(item_id) = raise(NotImplementedError, "#{self.class} must define #start")

  # Apply the claimed messages to the queue's state, dispatching a start
  # command for each item that gets a slot. Messages already applied
  # (at or before the row's last_position) are skipped. While replaying,
  # nothing is dispatched: the work was started then.
  #
  # @param claim [Sourced::ClaimResult]
  # @return [Array<Array(Array<Object>, Sourced::PositionedMessage)>] action/source pairs
  def handle(claim)
    queue = Queue.load(db, claim.partition_value.fetch('queue_name'), group_id: self.class.group_id)
    loaded_position = queue.last_position
    pairs = claim.messages.filter_map do |msg|
      next if msg.position <= queue.last_position

      message = msg.to_message
      kind = message.is_a?(self.class::Enqueue) ? :enqueue : :release
      started = queue.apply(kind, message.payload.item_id, capacity:, at: msg.created_at)
      queue.last_position = msg.position
      commands = claim.replaying ? [] : started.map { start(it) }
      [commands.empty? ? [Sourced::Actions::OK] : Sourced::Actions.build_for(commands), msg]
    end
    save = Sourced::Actions::Sync.new(-> { queue.save!(db, expected_position: loaded_position) })
    changed = Sourced::Actions::AfterSync.new(-> { publish_changed(queue.name, claim.messages.last) })
    pairs << [[save, changed], claim.messages.last]
  end

  private

  # After the claim commits, so a page reading .status sees what it saved.
  def publish_changed(name, source)
    signal = source.correlate(self.class::Changed.new(payload: { queue_name: name }))
    Sidereal::Integrations::Sourced.publish_messages([signal])
  end

  # One queue's state, as its row holds it.
  class Queue
    attr_reader :name, :group_id, :queued, :in_flight, :totals, :capacity
    attr_accessor :last_position

    # @return [Queue] the stored queue, or an empty one
    # @raise [ArgumentError] when another Queuer's group owns +name+
    def self.load(db, name, group_id:)
      row = db[TABLE].where(queue_name: name).first
      if row && row[:group_id] != group_id
        raise ArgumentError, "queue #{name.inspect} belongs to #{row[:group_id]}, not #{group_id}"
      end

      new(name, group_id:, row:)
    end

    def initialize(name, group_id:, row: nil)
      @name = name
      @group_id = group_id
      @stored = !row.nil?
      state = row ? JSON.parse(row[:state]) : {}
      @queued = state.fetch('queued', [])
      @in_flight = state.fetch('in_flight', {})
      @totals = %i[enqueued_total started_total released_total dropped_total].to_h { [it, row ? row[it] : 0] }
      @capacity = row ? row[:capacity] : 0
      @last_position = row ? row[:last_position] : 0
    end

    # Apply one Enqueue or Release, then fill the free slots, oldest first.
    # @param kind [:enqueue, :release]
    # @return [Array<String>] the items that got a slot
    def apply(kind, id, capacity:, at:)
      @capacity = capacity
      kind == :enqueue ? enqueue(id) : release(id)
      fill(at)
    end

    # Insert the row, or update it if it's still as loaded.
    # @raise [Conflict] when it isn't
    def save!(db, expected_position:)
      values = columns
      if @stored
        changed = db[TABLE].where(queue_name: name, last_position: expected_position).update(values)
        raise Conflict, "queue #{name.inspect} changed since position #{expected_position}" unless changed == 1
      else
        db[TABLE].insert(values.merge(queue_name: name, group_id:))
      end
    rescue Sequel::UniqueConstraintViolation
      raise Conflict, "queue #{name.inspect} was created by another claim"
    end

    private

    def enqueue(id)
      return if queued.include?(id) || in_flight.key?(id)

      queued << id
      totals[:enqueued_total] += 1
    end

    def release(id)
      if in_flight.delete(id)
        totals[:released_total] += 1
      elsif queued.delete(id)
        totals[:dropped_total] += 1
      end
    end

    def fill(at)
      started = []
      while in_flight.size < capacity && queued.any?
        id = queued.shift
        in_flight[id] = at.utc.iso8601
        totals[:started_total] += 1
        started << id
      end
      started
    end

    def columns
      {
        state: JSON.generate('queued' => queued, 'in_flight' => in_flight),
        capacity:, queued: queued.size, in_flight: in_flight.size, **totals,
        last_position:, updated_at: Time.now
      }
    end
  end
end
