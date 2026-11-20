# frozen_string_literal: true

module Expenses
  # The queue and the Expense machine together, through a store and router of
  # their own (a fresh database: the shared one holds other specs' messages),
  # with room for 2 scans.
  RSpec.describe ScanQueue do
    let(:db) { Sequel.sqlite.tap { Sequel::Migrator.run(it, File.expand_path('../db/migrations', __dir__)) } }
    let(:store) { Sourced::Store.new(db).tap { it.message_codec.compile! } }
    let(:reactors) { [Expense, ScanQueue] }
    let(:router) { Sourced::Router.new(store:, reactors:).tap(&:setup!) }
    let(:ids) { Array.new(3) { SecureRandom.hex(16) } }

    before do
      allow(ScanQueue).to receive(:new).and_wrap_original { |original, **deps| original.call(db:, max_scans: 2, **deps) }
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

    def started = store.read(Sourced::Selector[Expense::StartScan]).messages.map { it.payload.expense_id }
    def queue = db[:queues].where(queue_name: 'scans').first
    def state = JSON.parse(queue[:state])

    def paths(id)
      history = store.read(Expense.history_selector.bind(expense_id: id)).messages
      Expense.new(expense_id: id).tap { it.evolve(history) }.machine.paths
    end

    it 'starts as many scans as it has room for, and queues the rest, oldest first' do
      ids.each { upload(it) }
      drain

      expect(started).to eq(ids[0..1])
      expect(ids.map { paths(it).first }).to eq(%w[scanning scanning queued])
      expect(state['queued']).to eq([ids[2]])
      expect(state['in_flight'].keys).to eq(ids[0..1])
      expect(queue).to include(capacity: 2, queued: 1, in_flight: 2, enqueued_total: 3, started_total: 2,
                               released_total: 0, dropped_total: 0, group_id: 'expenses.scan_queue')
    end

    it 'starts the next one when a scan ends' do
      ids.each { upload(it) }
      drain
      send_command(Expense::TimeOutScan, ids[0])
      drain

      expect(started).to eq(ids)
      expect(paths(ids[0])).to include('scan_failed')
      expect(paths(ids[2]).first).to eq('scanning')
      expect(queue).to include(queued: 0, in_flight: 2, started_total: 3, released_total: 1)
    end

    it 'drops one discarded before its turn, starting nothing in its place' do
      ids.each { upload(it) }
      drain
      send_command(Expense::DiscardDocument, ids[2])
      drain

      expect(started).to eq(ids[0..1])
      expect(queue).to include(queued: 0, in_flight: 2, dropped_total: 1, released_total: 0)
    end

    it 'queues a rescan again, once its scan has ended' do
      upload(ids[0])
      drain
      send_command(Expense::TimeOutScan, ids[0])
      send_command(Expense::Rescan, ids[0])
      drain

      expect(started).to eq([ids[0], ids[0]])
      expect(queue).to include(in_flight: 1, enqueued_total: 2, started_total: 2, released_total: 1)
    end

    it 'ignores an Enqueue for one already queued or in flight, and a Release for one it never had' do
      upload(ids[0])
      drain
      store.append(ScanQueue::Enqueue.new(payload: { item_id: ids[0] }))
      store.append(ScanQueue::Release.new(payload: { item_id: 'unknown' }))
      router.handle_next_for(ScanQueue)

      expect(started).to eq([ids[0]])
      expect(queue).to include(in_flight: 1, enqueued_total: 1, released_total: 0, dropped_total: 0)
    end

    it 'rolls the claim back, start commands and all, when its row changed since it was loaded' do
      upload(ids[0])
      drain
      before = queue
      conflicts = []
      allow_any_instance_of(Queuer::Queue).to receive(:save!).and_wrap_original do |original, db, **kw|
        db[:queues].update(last_position: -1) # another claim of the queue, saving first
        original.call(db, **kw)
      rescue Queuer::Conflict => e
        conflicts << e
        raise
      end
      upload(ids[1])
      router.handle_next_for(Expense)
      router.handle_next_for(Expense)
      router.handle_next_for(ScanQueue)

      expect(conflicts.size).to eq(1)
      expect(started).to eq([ids[0]])
      expect(queue).to eq(before)
    end

    describe 'replaying' do
      def claim(*messages, replaying:)
        positioned = messages.each_with_index.map { |msg, i| Sourced::PositionedMessage.new(msg, i + 1) }
        Sourced::ClaimResult.new(offset_id: 1, key_pair_ids: [], partition_key: 'queue_name:scans',
                                 partition_value: { 'queue_name' => 'scans' }, messages: positioned,
                                 replaying:, guard: nil)
      end

      def run(pairs)
        pairs.flat_map { |actions, _| actions }.grep(Sourced::Actions::Sync).each(&:call)
        pairs.flat_map { |actions, _| actions }.grep(Sourced::Actions::Append).flat_map(&:messages)
      end

      it 'rebuilds the queue without dispatching, the work having started then' do
        enqueue = ScanQueue::Enqueue.new(payload: { item_id: ids[0] })
        appended = run(ScanQueue.new.handle(claim(enqueue, replaying: true)))

        expect(appended).to be_empty
        expect(state['in_flight'].keys).to eq([ids[0]])
      end

      it 'skips messages it has applied already' do
        enqueue = ScanQueue::Enqueue.new(payload: { item_id: ids[0] })
        run(ScanQueue.new.handle(claim(enqueue, replaying: false)))
        appended = run(ScanQueue.new.handle(claim(enqueue, replaying: false)))

        expect(appended).to be_empty
        expect(queue).to include(enqueued_total: 1, last_position: 1)
      end
    end

    describe 'its status and Changed signal' do
      it 'is an empty queue, with the capacity it has, before its first message' do
        expect(ScanQueue.status(db:)).to have_attributes(queue_name: 'scans', capacity: 2, queued: 0, in_flight: 0,
                                                         free: 2, idle?: true)
      end

      it "reads the row's counts" do
        ids.each { upload(it) }
        drain

        expect(ScanQueue.status(db:)).to have_attributes(capacity: 2, queued: 1, in_flight: 2, enqueued_total: 3,
                                                         started_total: 2, free: 0, idle?: false)
      end

      it 'publishes Changed once each claim of the queue has committed, on the queue’s channel' do
        published = []
        allow(Sidereal::Integrations::Sourced).to receive(:publish_messages) { |msgs| published.concat(msgs) }
        upload(ids[0])
        drain

        changed = published.grep(ScanQueue::Changed)
        expect(changed.map { it.payload.to_h }).to eq([{ queue_name: 'scans' }])
        expect(Sidereal.channels.for(changed.first)).to eq('expenses.queues.scans')
      end

      it 'publishes nothing for a claim rolled back' do
        upload(ids[0])
        drain
        published = []
        allow(Sidereal::Integrations::Sourced).to receive(:publish_messages) { |msgs| published.concat(msgs) }
        expect_any_instance_of(Queuer::Queue).to receive(:save!).and_raise(Queuer::Conflict)
        upload(ids[1])
        2.times { router.handle_next_for(Expense) }
        router.handle_next_for(ScanQueue)

        expect(published.grep(ScanQueue::Changed)).to be_empty
      end
    end

    it "refuses a queue another Queuer's group owns" do
      db[:queues].insert(queue_name: 'scans', group_id: 'other.queue', state: '{}', capacity: 1, last_position: 0,
                         updated_at: Time.now)
      claim = Sourced::ClaimResult.new(offset_id: 1, key_pair_ids: [], partition_key: '', partition_value: { 'queue_name' => 'scans' },
                                       messages: [], replaying: false, guard: nil)

      expect { ScanQueue.new.handle(claim) }.to raise_error(ArgumentError, /belongs to other\.queue/)
    end

    it 'registers on boot, as the queue for its commands, unlike the Queuer it subclasses' do
      expect(Sourced.registry.reactors).to include(ScanQueue)
      expect(Sourced.registry.reactors).not_to include(Queuer)
      expect(ScanQueue.claim_selector).to eq(Sourced::Selector[ScanQueue::Enqueue, ScanQueue::Release].by(:queue_name))
    end
  end
end
