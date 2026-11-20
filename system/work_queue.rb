# frozen_string_literal: true

require 'json'

# Capped work queues, as one Sourced reactor: in each queue, at most its
# capacity of items in flight, the rest waiting their turn, oldest first.
# Whoever has work enqueues it in a queue of their choosing, as the message to
# append when the item gets a slot (a command to start it, say), and releases
# it once the work is done or abandoned.
#
# A caller names its queue with .config, which builds its commands, to
# dispatch (a reaction's +dispatch+ takes anything answering +to_message+).
# What it declares it dispatches is the commands' classes:
#
#   ScanQueue = WorkQueue.define('scans')
#
#   entry WorkQueue::Enqueue do |_doc, entered|
#     dispatch ScanQueue.enqueue(StartScan, expense_id: entered.payload.expense_id).with_capacity(3)
#   end
#
#   # ...and once the scan is over:
#   exit WorkQueue::Release do |_doc, left_by|
#     dispatch ScanQueue.release(StartScan, expense_id: left_by.payload.expense_id)
#   end
#
# An item is its start message: its id is the message's type and its whole
# payload (.item_id), so releasing the same message, every attribute alike,
# releases the same item, and enqueueing it again while it's queued or in
# flight changes nothing.
#
# Each queue (queue_name) is one partition, with a state of its own: a
# caller with other work picks another name and gets another queue. Release
# to the queue the item was enqueued in: releasing an item a queue doesn't
# hold changes nothing.
#
# A queue's capacity is the one its latest Enqueue gave (recorded in
# Enqueued): raising it starts waiting items at once, lowering it stops
# nothing that's running, only what starts next. An Enqueue without one
# keeps the queue's, and a queue no Enqueue has given one has
# DEFAULT_CAPACITY.
#
# An item's start message is any registered message, by its type and
# payload, for any partition: the queue appends it as it is. Each item is one
# slot however long its work takes.
#
# What a queue decides is recorded as its events: Enqueued (with the item's
# capacity and start message), Started (the item got a slot, appended with
# its start message in the same commit), Released (its work ended) and
# Dropped (released before it started). Each event is correlated with the
# command that decided it, but a start message with the Enqueue that carried
# it, whichever command freed its slot: it carries on the caller's causal
# chain. Its state is those events folded
# (.fold), so replaying it, or reading it (.status), gives the same queue.
#
# It's a plain reactor, not a decider: a decider may only append messages in
# its own partition, and a start message is for someone else's.
#
# A queue every item passes through has a history with no end: the reactor
# snapshots each queue's state every SNAPSHOT_EVERY history messages, and a
# claim reads only the history after the last snapshot (Sourced::Snapshots).
# Bump SNAPSHOT_VERSION whenever the state's shape or .fold changes. .status
# reads a queue the same way, so there's no read model to keep: a page
# follows the queues' events, which an after_sync block publishes once
# committed.
#
#   on WorkQueue do |_evt| ... ScanQueue.status ... end
#
# It takes +sync+ and +after_sync+ blocks (Sourced::Sync), run for each
# command that appended anything, with +context:+ (the queue's state after
# it), +messages:+ (the command), +events:+ (the queue's events it appended,
# as stored) and +started:+ (the start messages it appended, as stored).
#
# An Enqueue whose start message isn't registered, or doesn't build, is a bug
# in whoever sent it: it raises, before anything is recorded, which stops
# the reactor's group. A start message can reach work that has moved on (ex.
# discarded while its slot was being given): it's for the receiver to refuse
# it, and the Release that follows frees the slot.
class WorkQueue
  include Sourced::Sync

  SNAPSHOT_EVERY = 100
  SNAPSHOT_VERSION = 4

  # The capacity of a queue no Enqueue has given one.
  DEFAULT_CAPACITY = 1

  TOTALS = %i[enqueued_total started_total released_total dropped_total].freeze

  # The message an item's slot appends: its type, and its payload.
  Start = Types::Hash[type: Types::String.present, payload: Types::Hash]

  ITEM = proc do
    attribute :queue_name, Types::String.present
    attribute :item_id, Types::String.present
  end

  ENQUEUE = proc do
    instance_exec(&ITEM)
    attribute :capacity, Types::Integer[1..].nullable.default(nil) # nil keeps the queue's
    attribute :start, Start
  end

  Enqueue = Sourced::Command.define('work_queue.enqueue', &ENQUEUE)
  Release = Sourced::Command.define('work_queue.release', &ITEM)
  Enqueued = Sourced::Event.define('work_queue.enqueued', &ENQUEUE)
  Started = Sourced::Event.define('work_queue.started', &ITEM)
  Released = Sourced::Event.define('work_queue.released', &ITEM)
  Dropped = Sourced::Event.define('work_queue.dropped', &ITEM)

  # A queue at a glance: what .status returns.
  Status = Data.define(:queue_name, :capacity, :queued, :in_flight, *TOTALS) do
    # @return [Integer] slots free now
    def free = [capacity - in_flight, 0].max

    # @return [Boolean] whether nothing is queued or in flight
    def idle? = queued.zero? && in_flight.zero?
  end

  # One queue, as its callers see it (.config): builds its commands.
  Queue = Data.define(:name) do
    # Enqueue an item: the message to append when it gets a slot.
    # @param start_class [Class<Sourced::Message>]
    # @param payload [Hash] the start message's payload
    # @return [Enqueuing] answers +to_message+, and #with_capacity
    def enqueue(start_class, **payload) = Enqueuing.new(queue_name: name, start_class:, payload:, capacity: nil)

    # Release the item that +start_class+ and +payload+ started.
    # @return [Release]
    def release(start_class, **payload)
      Release.new(payload: { queue_name: name, item_id: WorkQueue.item_id(start_class, payload) })
    end

    # @see WorkQueue.status
    def status(**) = WorkQueue.status(name, **)
  end

  # An Enqueue being built (Queue#enqueue).
  Enqueuing = Data.define(:queue_name, :start_class, :payload, :capacity) do
    # The queue's capacity from now on.
    # @param capacity [Integer]
    def with_capacity(capacity) = with(capacity:)

    # @return [Enqueue]
    def to_message
      Enqueue.new(payload: { queue_name:, capacity:, item_id: WorkQueue.item_id(start_class, payload),
                             start: { type: start_class.type, payload: } })
    end
  end

  class << self
    # The queue +name+, for a caller to enqueue in and release from.
    # @param name [String]
    # @return [Queue]
    def define(name) = Queue.new(name:)

    # An item's id: its start message's type and its payload as canonical
    # JSON (keys sorted, at every depth). The payload is the message's, as
    # built: attributes left out are there with their defaults.
    #
    # @param start_class [Class<Sourced::Message>]
    # @param payload [Hash]
    # @return [String] ex. 'expenses.start_scan:{"expense_id":"3a1b…"}'
    # @raise [ArgumentError] for a payload the message won't take: a bug in
    #   the caller, raised where it builds its Enqueue or Release
    def item_id(start_class, payload)
      message = start_class.new(payload:)
      raise ArgumentError, "#{start_class.type} #{message.errors[:payload].inspect}" unless message.valid?

      "#{start_class.type}:#{JSON.generate(canonical(message.payload.to_h))}"
    end

    # Sourced reactor protocol.
    def group_id = 'work_queue'

    # @return [Array<Class>]
    def handled_messages = [Enqueue, Release]

    # Sourced reactor protocol: its commands, one partition per queue.
    def claim_selector = Sourced::Selector[*handled_messages].by(*partition_keys)

    # What its partitions are by, as Sourced's consumers answer it (the
    # Sourced dashboard asks).
    # @return [Array<Symbol>]
    def partition_keys = %i[queue_name]

    # Sourced reactor protocol: its own events, read as history.
    def history_selector = Sourced::Selector[*events].by(:queue_name)

    # Sourced reactor protocol (Sourced::Snapshots).
    def snapshot_config
      @snapshot_config ||= Sourced::Snapshots::Config.parse(
        every: SNAPSHOT_EVERY, 
        version: SNAPSHOT_VERSION,
        type: Sourced::Types::JSONData
      )
    end

    # Sourced reactor protocol.
    def handle_claim(claim, history:, snapshot: nil) = new.handle(claim, history:, snapshot:)

    # Its events: what a queue's state is folded from, and what a page
    # showing queues follows (Sidereal's Page.on).
    # @return [Array<Class<Sourced::Event>>]
    def events = [Enqueued, Started, Released, Dropped]
    alias sidereal_events events

    # A queue's state before any event: no capacity yet.
    # @return [Hash]
    def empty = { capacity: nil, queued: [], in_flight: [], **TOTALS.to_h { [it, 0] } }

    # +state+ (an empty queue by default) with +messages+ applied, in order.
    # Queued items are { id:, type:, payload:, enqueue: } (+enqueue+: the
    # Enqueue that carried it, as .cause_of has it) and in-flight ones their
    # ids, oldest first: JSON-native with Symbol keys, so what a snapshot
    # stores comes back as it was. Other messages are skipped.
    #
    # @param messages [Array<Sourced::Message>]
    # @param state [Hash] updated in place
    # @return [Hash] +state+
    def fold(messages, state = empty)
      messages.each do |msg|
        msg = msg.to_message
        id = msg.payload.item_id if msg.payload.respond_to?(:item_id)
        case msg
        when Enqueued
          state[:capacity] = msg.payload.capacity if msg.payload.capacity
          item = { id:, **start_of(msg.payload.start), enqueue: cause_of(msg) }
          state[:queued] += [item] unless state[:queued].any? { it[:id] == id }
          state[:enqueued_total] += 1
        when Started
          state[:queued] = state[:queued].reject { it[:id] == id }
          state[:in_flight] |= [id]
          state[:started_total] += 1
        when Released
          state[:in_flight] -= [id]
          state[:released_total] += 1
        when Dropped
          state[:queued] = state[:queued].reject { it[:id] == id }
          state[:dropped_total] += 1
        end
      end
      state
    end

    # What the messages queue +name+ appends show as their producer (the
    # audit trail's "who dispatched it"): "work_queue(scans)".
    # @param name [String] the queue
    # @return [String]
    def producer_for(name) = "#{group_id}(#{name})"

    # The Enqueue an Enqueued was correlated with: its id, correlation id and
    # metadata (correlation_type included), what correlating with it copies.
    # @param enqueued [Enqueued]
    # @return [Hash] { id:, correlation_id:, metadata: }
    def cause_of(enqueued)
      { id: enqueued.causation_id, correlation_id: enqueued.correlation_id, metadata: enqueued.metadata.to_h }
    end

    # A start message's type and payload, with Symbol keys.
    # @return [Hash] { type:, payload: }
    def start_of(start)
      { type: start[:type] || start['type'], payload: (start[:payload] || start['payload']).to_h.transform_keys(&:to_sym) }
    end

    # The queue +name+ now: its last snapshot and the history after it, as a
    # claim reads them. An empty queue before its first message.
    #
    # @param name [String] the queue
    # @param capacity [Integer, nil] the capacity to show while no Enqueue
    #   has given it one (DEFAULT_CAPACITY by default)
    # @return [Status]
    def status(name, capacity: nil, store: Sourced.store)
      snapshot = stored_snapshot(store, name)
      history = store.read(history_selector.bind(queue_name: name), after_position: snapshot&.position)
      state = fold(history.messages, snapshot ? snapshot.state : empty)
      Status.new(queue_name: name, capacity: state[:capacity] || capacity || DEFAULT_CAPACITY, queued: state[:queued].size,
                 in_flight: state[:in_flight].size, **state.slice(*TOTALS))
    end

    private

    # +value+ with every Hash's keys as sorted Strings.
    def canonical(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, canonical(item)] }.sort.to_h
      when Array then value.map { canonical(it) }
      else value
      end
    end

    # The queue's snapshot, if it has one: none when the store hasn't
    # registered the reactor's group (no worker started it in this
    # process), which only means reading the queue's whole history.
    def stored_snapshot(store, name)
      offset = store.read_offsets(group_id:).to_enum.find { it[:partition_key] == "queue_name:#{name}" }
      offset && store.read_snapshot(group_id, offset_id: offset[:id])
    rescue Sourced::Store::SnapshotsNotRegisteredError
      nil
    end
  end

  # Decide each claimed command on its queue's state (+snapshot+'s, and
  # +history+ after it), appending its events and the start messages of the
  # items that get a slot, guarded by +history+: a claim of the queue that
  # read before another committed fails, to be retried. Once due, it stores
  # a snapshot of the history before the claim (Sourced::Snapshots).
  #
  # @param claim [Sourced::ClaimResult]
  # @param history [Sourced::ReadResult] the queue's events after +snapshot+
  # @param snapshot [Sourced::Snapshot, nil]
  # @return [Array<Array(Array<Object>, Sourced::PositionedMessage)>] action/source pairs
  def handle(claim, history:, snapshot:)
    state = self.class.fold(history.messages, snapshot ? snapshot.state : self.class.empty)
    pairs = claim.messages.map do |msg|
      decided = decide(state, msg.to_message)
      next [Sourced::Actions::OK, msg] if decided.empty?

      # In order, each run of messages appended with what it's correlated
      # with: the claimed command, or a start message's Enqueue.
      # Each produced by this queue, not by whoever its source's producer was
      # (correlating copies metadata; a message's own wins).
      producer = self.class.producer_for(msg.payload.queue_name)
      appends = decided.chunk_while { |a, b| a.last.equal?(b.last) }.flat_map do |run|
        messages = run.map { |message, _| message.with_metadata(producer:) }
        Sourced::Actions.build_for(messages, guard: history.guard, source: run.first.last || msg)
      end
      hooks = collect_actions(context: state, messages: [msg]) do |appended|
        events, started = appended.partition { self.class.events.include?(it.class) }
        { events:, started: }
      end
      [[*appends, *hooks], msg]
    end
    with_snapshot(pairs, snapshot_signal(claim, history, snapshot))
  end

  # The messages +command+ appends, folding the queue's own into +state+,
  # each with what it's correlated with: nil for +command+ itself, or the
  # Enqueue that carried a start message.
  # @param state [Hash] updated in place
  # @param command [Sourced::Message] an Enqueue or Release
  # @return [Array<Array(Sourced::Message, Sourced::Message, nil)>]
  def decide(state, command)
    queue_name = command.payload.queue_name
    id = command.payload.item_id
    queued = state[:queued].any? { it[:id] == id }
    appended = []

    case command
    when Enqueue
      unless queued || state[:in_flight].include?(id)
        start_message(command.payload.start) # raises for a start it can't append
        # Correlated now, so the item it folds into knows its Enqueue.
        appended << command.correlate(Enqueued.new(payload: command.payload.to_h))
      end
    when Release
      if state[:in_flight].include?(id)
        appended << Released.new(payload: { queue_name:, item_id: id })
      elsif queued
        appended << Dropped.new(payload: { queue_name:, item_id: id })
      end
    end
    self.class.fold(appended, state)
    appended.map { [it, nil] } + fill(state, queue_name)
  end

  private

  # Start the oldest queued items while there's room: Started, and each
  # item's start message, correlated with its Enqueue.
  def fill(state, queue_name)
    appended = []
    capacity = state[:capacity] || DEFAULT_CAPACITY
    while state[:in_flight].size < capacity && (item = state[:queued].first)
      started = Started.new(payload: { queue_name:, item_id: item[:id] })
      self.class.fold([started], state)
      appended << [started, nil] << [start_message(item), enqueue_of(item, queue_name)]
    end
    appended
  end

  # The Enqueue that carried +item+, as far as correlating with it goes.
  def enqueue_of(item, queue_name)
    cause = item[:enqueue]
    Enqueue.new(id: cause[:id], correlation_id: cause[:correlation_id], metadata: cause[:metadata],
                payload: { queue_name:, item_id: item[:id], start: item.slice(:type, :payload) })
  end

  # The message +start+ describes.
  # @raise [ArgumentError] when its type isn't registered, or it doesn't build
  def start_message(start)
    start = self.class.start_of(start)
    klass = Sourced::Message.registry[start[:type]]
    raise ArgumentError, "#{self.class}: no message is registered as #{start[:type].inspect}" unless klass

    message = klass.new(payload: start[:payload])
    raise ArgumentError, "#{self.class}: #{start[:type]} #{message.errors[:payload].inspect}" unless message.valid?

    message
  end

  # Due once the history before the claim has +every+ messages since
  # +snapshot+ (.snapshot_config): its state over that part of the history,
  # from a fold of its own (deciding changed the claim's). Below the claim's
  # first message, as Sourced requires.
  def snapshot_signal(claim, history, snapshot)
    prior = history.messages.select { it.position < claim.messages.first.position }
    return if prior.size < self.class.snapshot_config.every

    state = self.class.fold(prior, snapshot ? snapshot.state : self.class.empty)
    Sourced::Actions::Snapshot.new(state:, position: prior.last.position)
  end

  # +pairs+ with +signal+ added to the first pair's actions, so it's stored
  # when any of the claim is acked.
  def with_snapshot(pairs, signal)
    return pairs unless signal

    (actions, msg), *rest = pairs
    [[[signal, *Array(actions)], msg], *rest]
  end

  # The queues' own events, for pages showing them, once committed.
  after_sync do |events: [], **|
    Sidereal::Integrations::Sourced.publish_messages(events) if events.any?
  end
end
