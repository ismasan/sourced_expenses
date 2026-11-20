# frozen_string_literal: true

# The queues and the Expense machine together, through a store and router of
# their own (a fresh database: the shared one holds other specs' messages).
# Expenses scan 2 at once.
module Expenses
  RSpec.describe WorkQueue do
    let(:db) { Sequel.sqlite.tap { Sequel::Migrator.run(it, File.expand_path('../db/migrations', __dir__)) } }
    let(:store) { Sourced::Store.new(db).tap { it.message_codec.compile! } }
    let(:router) { Sourced::Router.new(store:, reactors: [Expense, WorkQueue]).tap(&:setup!) }
    let(:reactors) { [Expense, WorkQueue] }
    let(:ids) { Array.new(3) { SecureRandom.hex(16) } }

    before do
      allow_any_instance_of(Expense).to receive(:max_scans).and_return(2)
      router
    end

    def drain
      loop { break unless reactors.map { router.handle_next_for(it) }.any? }
    end

    def upload(id)
      store.append(Expense::UploadDocument.new(payload: { expense_id: id, filename: "#{id}.pdf", content_type: 'application/pdf',
                                                          file_ref: "f/#{id}", filing_country: 'NL' }))
    end

    def send_command(klass, id, **payload) = store.append(klass.new(payload: { expense_id: id, **payload }))
    def job(id) = WorkQueue.item_id(Expense::StartScan, expense_id: id)
    def start(id) = { type: Expense::StartScan.type, payload: { expense_id: id } }

    def enqueue(id, capacity: nil, queue: Expense::ScanQueue)
      enqueuing = queue.enqueue(Expense::StartScan, expense_id: id)
      store.append((capacity ? enqueuing.with_capacity(capacity) : enqueuing).to_message)
    end

    # The expenses whose scan got a slot, in order.
    def started = store.read(Sourced::Selector[Expense::StartScan]).messages.map { it.payload.expense_id }
    def stats(name = 'scans') = WorkQueue.status(name, store:).to_h
    def history(name = 'scans') = store.read(WorkQueue.history_selector.bind(queue_name: name)).messages

    # A queue's state, from its whole history.
    def state(name = 'scans') = WorkQueue.fold(history(name))
    def queued_ids = state[:queued].map { it[:id] }

    # Each expense's Enqueue, and its StartScan, by expense id.
    def enqueue_of(id) = store.read(Sourced::Selector[WorkQueue::Enqueue]).messages.find { it.payload.item_id == job(id) }
    def start_scan_of(id) = store.read(Sourced::Selector[Expense::StartScan]).messages.find { it.payload.expense_id == id }

    def correlated_with?(message, source)
      message.causation_id == source.id && message.correlation_id == source.correlation_id &&
        message.correlation_type == source.correlation_type
    end

    def paths(id)
      expense_history = store.read(Expense.history_selector.bind(expense_id: id)).messages
      Expense.new(expense_id: id).tap { it.evolve(expense_history) }.machine.paths
    end

    it 'starts as many scans as it has room for, and queues the rest, oldest first' do
      ids.each { upload(it) }
      drain

      expect(started).to eq(ids[0..1])
      expect(ids.map { paths(it).first }).to eq(%w[scanning scanning queued])
      expect(queued_ids).to eq([job(ids[2])])
      expect(state[:in_flight]).to eq(ids[0..1].map { job(it) })
      expect(stats).to include(capacity: 2, queued: 1, in_flight: 2, enqueued_total: 3, started_total: 2, released_total: 0,
                               dropped_total: 0)
    end

    it "records what it decides as events, appending each item's start message with its Started" do
      upload(ids[0])
      drain

      decided = store.read(Sourced::Selector[WorkQueue::Started, Expense::StartScan]).messages
      expect(decided.map(&:class)).to eq([WorkQueue::Started, Expense::StartScan])
      expect(decided.map(&:position)).to eq([decided[0].position, decided[0].position + 1])
      expect(decided[1].payload.to_h).to eq(expense_id: ids[0])
      expect(history.map(&:class)).to eq([WorkQueue::Enqueued, WorkQueue::Started])
    end

    it 'runs its sync and after_sync blocks with the queue, the command, its events and the start messages, as stored' do
      seen = { sync: [], after_sync: [] }
      hooks = { sync: proc { |**kw| seen[:sync] << kw }, after_sync: proc { |**kw| seen[:after_sync] << kw } }
      WorkQueue.sync_blocks << hooks[:sync]
      WorkQueue.after_sync_blocks << hooks[:after_sync]
      upload(ids[0])
      drain

      seen.each_value do |calls|
        expect(calls.size).to eq(1)
        call = calls.first
        expect(call[:messages].map(&:class)).to eq([WorkQueue::Enqueue])
        expect(call[:events].map(&:class)).to eq([WorkQueue::Enqueued, WorkQueue::Started])
        expect(call[:events].map(&:id)).to eq(history.map(&:id))
        expect(call[:started].map(&:class)).to eq([Expense::StartScan])
        expect(call[:started].first.causation_id).to eq(enqueue_of(ids[0]).id)
        expect(call[:context]).to include(in_flight: [job(ids[0])])
      end
    ensure
      WorkQueue.sync_blocks.delete(hooks[:sync])
      WorkQueue.after_sync_blocks.delete(hooks[:after_sync])
    end

    describe 'correlation' do
      it 'correlates a start message with the Enqueue that carried it, on its caller’s causal chain' do
        upload(ids[0])
        drain
        enqueue = enqueue_of(ids[0])
        upload_command = store.read(Sourced::Selector[Expense::UploadDocument]).messages.first

        expect(correlated_with?(start_scan_of(ids[0]), enqueue)).to be(true)
        expect(start_scan_of(ids[0]).correlation_id).to eq(upload_command.correlation_id)
        expect(start_scan_of(ids[0]).correlation_type).to eq(Expense::UploadDocument.type)
      end

      it 'keeps to it when another command frees the slot, and the queue’s own events to the command that decided them' do
        ids.each { upload(it) }
        drain
        send_command(Expense::TimeOutScan, ids[0])
        drain
        release = store.read(Sourced::Selector[WorkQueue::Release]).messages.first
        started = history.select { it.is_a?(WorkQueue::Started) }.last

        expect(correlated_with?(start_scan_of(ids[2]), enqueue_of(ids[2]))).to be(true)
        expect(start_scan_of(ids[2]).causation_id).not_to eq(release.id)
        expect(started.payload.item_id).to eq(job(ids[2]))
        expect(correlated_with?(started, release)).to be(true)
      end

      it 'shows the queue as the producer of what it appends, and its caller as the Enqueue’s' do
        ids.each { upload(it) }
        drain
        send_command(Expense::TimeOutScan, ids[0])
        drain

        expect(enqueue_of(ids[0]).metadata[:producer]).to eq(Expense.group_id)
        expect(store.read(Sourced::Selector[WorkQueue::Release]).messages.map { it.metadata[:producer] }).to all(eq(Expense.group_id))
        expect(history.map { it.metadata[:producer] }.uniq).to eq(['work_queue(scans)'])
        expect(ids.map { start_scan_of(it).metadata[:producer] }).to all(eq('work_queue(scans)'))
      end
    end

    it 'starts the next one when a scan ends' do
      ids.each { upload(it) }
      drain
      send_command(Expense::TimeOutScan, ids[0])
      drain

      expect(started).to eq(ids)
      expect(paths(ids[0])).to include('scan_failed')
      expect(paths(ids[2]).first).to eq('scanning')
      expect(stats).to include(queued: 0, in_flight: 2, started_total: 3, released_total: 1)
    end

    it 'drops one discarded before its turn, starting nothing in its place' do
      ids.each { upload(it) }
      drain
      send_command(Expense::DiscardDocument, ids[2])
      drain

      expect(started).to eq(ids[0..1])
      expect(history.last).to be_a(WorkQueue::Dropped)
      expect(stats).to include(queued: 0, in_flight: 2, dropped_total: 1, released_total: 0)
    end

    it 'queues a rescan again, once its scan has ended' do
      upload(ids[0])
      drain
      send_command(Expense::TimeOutScan, ids[0])
      send_command(Expense::Rescan, ids[0])
      drain

      expect(started).to eq([ids[0], ids[0]])
      expect(stats).to include(in_flight: 1, enqueued_total: 2, started_total: 2, released_total: 1)
    end

    it 'ignores an Enqueue for one already queued or in flight, and a Release for one it never had' do
      upload(ids[0])
      drain
      enqueue(ids[0], capacity: 5)
      store.append(WorkQueue::Release.new(payload: { queue_name: 'scans', item_id: 'unknown' }))
      drain

      expect(started).to eq([ids[0]])
      expect(history.size).to eq(2)
      expect(stats).to include(capacity: 2, in_flight: 1, enqueued_total: 1, released_total: 0, dropped_total: 0)
    end

    describe 'a queue, as its callers name it' do
      let(:queue) { WorkQueue.config('scans') }
      let(:id) { ids[0] }

      it 'builds an Enqueue of the start message, its id the message’s type and payload' do
        enqueue = queue.enqueue(Expense::StartScan, expense_id: id).with_capacity(3).to_message

        expect(enqueue).to be_a(WorkQueue::Enqueue)
        expect(enqueue.payload.to_h).to eq(queue_name: 'scans', capacity: 3, item_id: %(expenses.start_scan:{"expense_id":"#{id}"}),
                                           start: start(id))
        expect(queue.enqueue(Expense::StartScan, expense_id: id).to_message.payload.capacity).to be_nil
      end

      it 'ids an item by its whole payload as built, unambiguously, whatever the order of its keys' do
        start = Sourced::Command.define('work_queue_spec.start') do
          attribute :name, String
          attribute :tag, String
          attribute :on, Date
          attribute :extra, Types::Hash.default({}.freeze)
        end
        id = ->(**payload) { WorkQueue.item_id(start, payload) }

        on = Date.new(2026, 8, 9)

        expect(id.(name: 'x', tag: 'y', on:)).to eq(id.(on:, tag: 'y', name: 'x'))
        expect(id.(name: 'x', tag: 'y', on:)).to eq(id.(name: 'x', tag: 'y', on:, extra: {}))
        expect(id.(name: 'x,tag=y', tag: 'z', on:)).not_to eq(id.(name: 'x', tag: 'y,tag=z', on:))
        expect(id.(name: 'x', tag: 'y', on:, extra: { b: 1, a: [{ d: 2, c: 3 }] }))
          .to eq(id.(name: 'x', tag: 'y', on:, extra: { a: [{ c: 3, d: 2 }], b: 1 }))
        expect(id.(name: 'x', tag: 'y', on:)).to eq('work_queue_spec.start:{"extra":{},"name":"x","on":"2026-08-09","tag":"y"}')
      end

      it 'refuses a start message that won’t build, where the caller builds its command' do
        expect { queue.enqueue(Expense::StartScan, expense_id: 'not an id').to_message }.to raise_error(ArgumentError, /expense_id/)
        expect { queue.release(Expense::StartScan, expense_id: 'not an id') }.to raise_error(ArgumentError, /expense_id/)
      end

      it 'builds a Release of the same item' do
        release = queue.release(Expense::StartScan, expense_id: id)

        expect(release).to be_a(WorkQueue::Release)
        expect(release.payload.to_h).to eq(queue_name: 'scans', item_id: job(id))
      end

    end

    describe 'its capacity, the one its latest Enqueue gave' do
      it 'is kept by an Enqueue without one' do
        ids.each { upload(it) }
        drain
        extra = SecureRandom.hex(16)
        enqueue(extra)
        drain

        expect(stats).to include(capacity: 2, queued: 2, in_flight: 2)
      end

      it 'is DEFAULT_CAPACITY until an Enqueue gives it one' do
        queue = WorkQueue.config('other')
        enqueue(ids[0], queue:)
        enqueue(ids[1], queue:)
        drain

        expect(WorkQueue.status('other', store:)).to have_attributes(capacity: WorkQueue::DEFAULT_CAPACITY, in_flight: 1, queued: 1)
        expect(WorkQueue.status('nothing', store:).capacity).to eq(WorkQueue::DEFAULT_CAPACITY)
      end

      it 'starts waiting items at once when raised' do
        ids.each { upload(it) }
        drain
        extra = SecureRandom.hex(16)
        enqueue(extra, capacity: 4)
        drain

        expect(started).to eq([*ids[0..1], ids[2], extra])
        expect(stats).to include(capacity: 4, queued: 0, in_flight: 4)
      end

      it 'stops nothing running when lowered, only what starts next' do
        ids.each { upload(it) }
        drain
        extra = SecureRandom.hex(16)
        enqueue(extra, capacity: 1)
        send_command(Expense::TimeOutScan, ids[0])
        drain

        expect(started).to eq(ids[0..1])
        expect(stats).to include(capacity: 1, queued: 2, in_flight: 1)
      end
    end

    it 'keeps queues apart: each queue_name has its own capacity, items and counts' do
      ids.each { upload(it) }
      drain
      other = SecureRandom.hex(16)
      enqueue(other, capacity: 1, queue: WorkQueue.config('other'))
      drain

      expect(started).to eq([*ids[0..1], other])
      expect(stats('other')).to include(capacity: 1, in_flight: 1, queued: 0, enqueued_total: 1)
      expect(stats).to include(capacity: 2, in_flight: 2, queued: 1, enqueued_total: 3)
    end

    describe 'an Enqueue it can’t start' do
      def decide(start)
        WorkQueue.new.decide(WorkQueue.empty, WorkQueue::Enqueue.new(payload: { queue_name: 'q', capacity: 1, item_id: 'job', start: }))
      end

      it 'raises for a message type nothing registers' do
        expect { decide(type: 'expenses.nothing', payload: {}) }
          .to raise_error(ArgumentError, /no message is registered as "expenses.nothing"/)
      end

      it 'raises for a payload its message won’t take' do
        expect { decide(type: Expense::StartScan.type, payload: { expense_id: 'not an id' }) }
          .to raise_error(ArgumentError, /expense_id/)
      end

      it "stops the reactor's group, recording nothing" do
        upload(ids[0])
        drain
        store.append(WorkQueue::Enqueue.new(payload: { queue_name: 'scans', capacity: 2, item_id: 'job',
                                                    start: { type: 'expenses.nothing', payload: {} } }))
        router.handle_next_for(WorkQueue)

        expect(history.size).to eq(2)
        expect(db[:sourced_consumer_groups].where(group_id: WorkQueue.group_id).get(:status)).to eq('failed')
      end
    end

    describe 'snapshots' do
      let(:router) do
        allow(WorkQueue).to receive(:snapshot_config)
          .and_return(Sourced::Snapshots::Config.parse(every: 2, version: 1, type: Sourced::Types::JSONData))
        Sourced::Router.new(store:, reactors: [Expense, WorkQueue]).tap(&:setup!)
      end
      let(:ids) { Array.new(4) { SecureRandom.hex(16) } }

      def snapshot = db[:sourced_snapshots].first
      def snapshot_state = JSON.parse(snapshot[:state], symbolize_names: true)

      it 'stores a queue’s state every so often, waiting items, their start messages and its capacity too, and starts them from it' do
        ids.each { upload(it) }
        drain
        send_command(Expense::TimeOutScan, ids[0])
        drain
        expect(snapshot_state[:capacity]).to eq(2)
        expect(snapshot_state[:queued].map { it.slice(:id, :type, :payload) }).to eq(ids[2..3].map { { id: job(it), **start(it) } })
        expect(snapshot_state[:queued].map { it[:enqueue][:id] }).to eq(ids[2..3].map { enqueue_of(it).id })

        reads = []
        allow(store).to receive(:read).and_wrap_original do |original, selector, **kw|
          reads << kw[:after_position] if selector.types.include?(WorkQueue::Enqueued)
          original.call(selector, **kw)
        end
        position = snapshot[:position]
        send_command(Expense::TimeOutScan, ids[1])
        drain

        expect(reads.first).to eq(position)
        expect(started).to eq(ids)
        expect(ids[2..3].map { correlated_with?(start_scan_of(it), enqueue_of(it)) }).to eq([true, true])
        expect(state).to include(queued: [], in_flight: ids[2..3].map { job(it) })
      end
    end

    describe 'its status' do
      it 'is an empty queue before its first message, with the capacity it’s told' do
        expect(WorkQueue.status('scans', capacity: 3, store:)).to have_attributes(queue_name: 'scans', capacity: 3, queued: 0,
                                                                                in_flight: 0, free: 3, idle?: true)
      end

      it 'reads the queue as a claim does: its snapshot, and the history after it' do
        allow(WorkQueue).to receive(:snapshot_config)
          .and_return(Sourced::Snapshots::Config.parse(every: 3, version: 1, type: Sourced::Types::JSONData))
        ids.each { upload(it) }
        drain
        position = db[:sourced_snapshots].get(:position)
        reads = []
        allow(store).to receive(:read).and_wrap_original do |original, selector, **kw|
          reads << kw[:after_position]
          original.call(selector, **kw)
        end

        expect(WorkQueue.status('scans', capacity: 9, store:)).to have_attributes(capacity: 2, queued: 1, in_flight: 2,
                                                                                enqueued_total: 3, started_total: 2,
                                                                                free: 0, idle?: false)
        expect(reads).to eq([position])
      end

      it "reads the whole history where the store hasn't registered its snapshots" do
        ids.each { upload(it) }
        drain

        expect(WorkQueue.status('scans', store: Sourced::Store.new(db))).to have_attributes(queued: 1, in_flight: 2)
      end

      it "publishes its events once they're committed, on the queue's channel" do
        published = []
        allow(Sidereal::Integrations::Sourced).to receive(:publish_messages) { |msgs| published.concat(msgs) }
        upload(ids[0])
        drain

        events = published.select { WorkQueue.sidereal_events.include?(it.class) }
        expect(events.map(&:class)).to eq([WorkQueue::Enqueued, WorkQueue::Started])
        expect(events.map { Sidereal.channels.for(it) }.uniq).to eq(['expenses.queues.scans'])
      end
    end

    it 'registers on boot, claiming its commands by queue_name' do
      expect(Sourced.registry.reactors).to include(WorkQueue)
      expect(WorkQueue.claim_selector).to eq(Sourced::Selector[WorkQueue::Enqueue, WorkQueue::Release].by(:queue_name))
      expect(WorkQueue.group_id).to eq('work_queue')
      expect(WorkQueue.partition_keys).to eq(%i[queue_name])
    end
  end
end
