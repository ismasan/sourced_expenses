# frozen_string_literal: true

require 'sourced/testing/rspec'

module FreeAgent
  class Import
    RSpec.describe Import do
      include Sourced::Testing::RSpec

      let(:import_id) { 'freeagent' }
      let(:category_url) { 'https://api.freeagent.com/v2/categories/285' }

      before do
        FAKE_FREEAGENT.categories = {
          category_url => FreeAgent::Client::Category.new(url: category_url, nominal_code: '285',
                                                          description: 'Accommodation and Meals')
        }
      end

      def cmd(klass, **payload) = klass.new(payload: { import_id:, **payload })
      def history(*commands, given: []) = decided(Import, { import_id: }, *commands, given:)
      def run(history) = Import.new(import_id:).tap { it.evolve(history) }
      def value(history) = run(history).machine.value

      # What the machine dispatches claiming the last state event in
      # +history+, as the runtime would.
      def dispatched_entering(history)
        *before, entered = history
        messages = nil
        before.reduce(with_reactor(Import, import_id:)) { |gwt, msg| gwt.given(msg) }
              .when(entered).then { |result| messages = result.messages }
        messages
      end

      # A FreeAgent expense, as its API answers.
      def expense(id, updated_at: '2026-11-20T10:00:00Z', **overrides)
        { 'url' => "https://api.freeagent.com/v2/expenses/#{id}", 'category' => category_url, 'dated_on' => '2026-11-18',
          'currency' => 'GBP', 'gross_value' => '-24.0', 'sales_tax_value' => '-4.0', 'sales_tax_rate' => '20.0',
          'ec_status' => 'UK/Non-EC', 'description' => "Lunch #{id}", 'updated_at' => updated_at,
          **overrides.transform_keys(&:to_s) }
      end

      # Runs the history's entries and the commands they dispatch, as the
      # runtime would, until the machine stops fetching. The ImportExpenses
      # dispatched along the way are collected in +imports+.
      def sync(given: [], since: nil, imports: [])
        history = history(cmd(SyncFreeAgent, since:), given:)
        loop do
          dispatched = dispatched_entering(history)
          imports.concat(dispatched.grep(Expenses::Expense::ImportExpense))
          own = dispatched.grep(CompleteFetch) + dispatched.grep(FailFetch)
          break if own.empty?

          history = history(*own, given: history)
        end
        history
      end

      describe 'snapshots' do
        # +history+'s machine, through a snapshot as the store keeps one: its
        # state encoded through the snapshot type's JSON codec (as
        # Sourced::Store#write_snapshot does), and decoded back.
        def through_snapshot(history)
          decoder, encoder = Plumb::Codec::JSON.for(Import.snapshot_config.type)
          json = JSON.dump(encoder.parse(run(history).snapshot_state))
          Import.new(import_id:).tap { it.restore_snapshot_state(decoder.parse(JSON.parse(json))) }
        end

        it 'are taken every SNAPSHOT_EVERY messages, at their version' do
          expect(Import.snapshot_config).to have_attributes(every: Import::SNAPSHOT_EVERY,
                                                                     version: Import::SNAPSHOT_VERSION)
        end

        it 'keep where the next run starts, its times as times, and the last failure' do
          FAKE_FREEAGENT.pages = [[expense(1)]]
          done = sync
          FAKE_FREEAGENT.pages = FreeAgent::Error.new('FreeAgent could not be reached')
          failed = sync(given: done)
          restored = through_snapshot(failed)

          expect(restored.context).to eq(run(failed).context)
          expect(restored.context[:cursor]).to eq(Time.utc(2026, 11, 20, 10))
          expect(restored.context[:failure]).to include(reason: 'FreeAgent could not be reached', at: be_a(Time))
          expect(restored.machine.value).to eq(Failed)
        end

        it 'start the next run from where the last one finished' do
          FAKE_FREEAGENT.pages = [[expense(1)]]
          restored = through_snapshot(sync)

          started = restored.decide(cmd(SyncFreeAgent)).grep(SyncStarted)
          expect(started.map { it.payload.updated_since }).to eq([Time.utc(2026, 11, 20, 9, 59)])
        end
      end

      it 'is a valid chart' do
        expect(Import.to_h).to include(:states)
      end

      it 'imports every page, then waits for the next run' do
        FAKE_FREEAGENT.pages = [[expense(1), expense(2)], [expense(3, updated_at: '2026-11-21T09:00:00Z')]]
        imports = []
        done = sync(imports:)

        expect(value(done)).to eq(Idle)
        expect(FAKE_FREEAGENT.calls).to eq([{ updated_since: nil, page: 1 }, { updated_since: nil, page: 2 }])
        expect(imports.map { it.payload.expense_id }).to eq(%w[freeagent-1 freeagent-2 freeagent-3])
        expect(run(done).context).to include(cursor: Time.utc(2026, 11, 21, 9), synced_count: 3, fetching: false)
      end

      it 'links each expense to its page on the company’s FreeAgent site' do
        FAKE_FREEAGENT.pages = [[expense(1, user: 'https://api.freeagent.com/v2/users/42')]]
        imports = []
        sync(imports:)

        expect(imports.map { it.payload.external_url }).to eq(['https://example.freeagent.com/users/42/expenses/1/edit'])
      end

      it 'starts the next run from the latest change the last one read' do
        FAKE_FREEAGENT.pages = [[expense(1)]]
        first = sync
        FAKE_FREEAGENT.calls.clear
        FAKE_FREEAGENT.pages = []
        second = sync(given: first)

        # A minute before, as updated_since may not include the time itself.
        expect(FAKE_FREEAGENT.calls).to eq([{ updated_since: Time.utc(2026, 11, 20, 9, 59), page: 1 }])
        expect(run(second).context[:cursor]).to eq(Time.utc(2026, 11, 20, 10))
      end

      # FreeAgent answers with what was updated since a minute before the
      # last run finished: the last ones it read come again, changing nothing.
      it 'counts only what was updated after the last run finished as new or changed' do
        FAKE_FREEAGENT.pages = [[expense(1, updated_at: '2026-11-20T09:00:00Z'), expense(2, updated_at: '2026-11-20T10:00:00Z')]]
        first = sync
        expect(run(first).context).to include(synced_count: 2, synced_fresh: 2)

        # The overlap: expense 2 again, and a new one.
        FAKE_FREEAGENT.pages = [[expense(2, updated_at: '2026-11-20T10:00:00Z'), expense(3, updated_at: '2026-11-21T08:00:00Z')]]
        second = sync(given: first)
        expect(run(second).context).to include(synced_count: 2, synced_fresh: 1)

        # Nothing more: expense 3 again.
        FAKE_FREEAGENT.pages = [[expense(3, updated_at: '2026-11-21T08:00:00Z')]]
        third = sync(given: second)
        expect(run(third).context).to include(synced_count: 1, synced_fresh: 0)
      end

      it 'skips a run while FreeAgent isn’t connected, recording nothing' do
        FAKE_FREEAGENT.connected = false
        expect(history(cmd(SyncFreeAgent))).to be_empty

        FAKE_FREEAGENT.connected = true
        FAKE_FREEAGENT.pages = [[expense(1)]]
        done = sync
        FAKE_FREEAGENT.connected = false
        FAKE_FREEAGENT.calls.clear

        expect(history(cmd(SyncFreeAgent), given: done)).to eq(done)
        expect(value(done)).to eq(Idle)
        expect(FAKE_FREEAGENT.calls).to be_empty
      end

      it 'backfills from a date given' do
        sync(since: Time.utc(2026, 1, 1))

        expect(FAKE_FREEAGENT.calls.first).to eq(updated_since: Time.utc(2026, 1, 1), page: 1)
      end

      it 'fails without moving the cursor, and starts again from it next time' do
        FAKE_FREEAGENT.pages = [[expense(1)]]
        first = sync
        FAKE_FREEAGENT.pages = FreeAgent::Error.new('FreeAgent is rate limiting requests: try again in 60 seconds')
        failed = sync(given: first)

        expect(value(failed)).to eq(Failed)
        expect(run(failed).context).to include(cursor: Time.utc(2026, 11, 20, 10),
                                               failure: include(reason: 'FreeAgent is rate limiting requests: try again in 60 seconds'))
        FAKE_FREEAGENT.pages = []
        FAKE_FREEAGENT.calls.clear
        expect(value(sync(given: failed))).to eq(Idle)
        expect(FAKE_FREEAGENT.calls).to eq([{ updated_since: Time.utc(2026, 11, 20, 9, 59), page: 1 }])
      end

      it 'skips what isn’t an expense here, counting it' do
        FAKE_FREEAGENT.pages = [[expense(1), expense(2, category: 'Mileage', gross_value: nil), expense(3, currency: 'Pounds')]]
        imports = []
        done = sync(imports:)

        expect(imports.map { it.payload.expense_id }).to eq(%w[freeagent-1])
        expect(done.grep(PageFetched).map { [it.payload.count, it.payload.skipped] }).to eq([[1, 2]])
      end

      it 'leaves out an expense uploaded from here, counting it neither way' do
        db = Sidereal.config['db']
        db[:freeagent_uploads].insert(external_id: '2', expense_id: SecureRandom.uuid, uploaded_at: Time.now)
        FAKE_FREEAGENT.pages = [[expense(1), expense(2)]]
        imports = []
        done = sync(imports:)

        expect(imports.map { it.payload.expense_id }).to eq(%w[freeagent-1])
        expect(done.grep(PageFetched).map { [it.payload.count, it.payload.skipped] }).to eq([[1, 0]])
      ensure
        db[:freeagent_uploads].delete
      end

      it 'skips an expense FreeAgent sent without what an expense needs, and goes on' do
        FAKE_FREEAGENT.pages = [[expense(1, dated_on: nil), expense(2, url: nil), expense(3, gross_value: 'lots'), expense(4)]]
        imports = []
        done = sync(imports:)

        expect(value(done)).to eq(Idle)
        expect(imports.map { it.payload.expense_id }).to eq(%w[freeagent-4])
        expect(done.grep(PageFetched).map { [it.payload.count, it.payload.skipped] }).to eq([[1, 3]])
      end

      it 'takes no new run while one is fetching, and times a stuck one out' do
        fetching = history(cmd(SyncFreeAgent))

        expect(run(fetching).handles_command?(cmd(SyncFreeAgent))).to be(false)
        expect(value(history(cmd(TimeOutFetch), given: fetching))).to eq(Failed)
      end

      it 'reads nothing for a fetching entered before the one it is in (a group catching up)' do
        import_id = "freeagent-#{SecureRandom.hex(4)}"
        first_page = decided(Import, { import_id: }, SyncFreeAgent.new(payload: { import_id: }))
        second_page = decided(Import, { import_id: },
                              CompleteFetch.new(payload: { import_id:, page: 1, count: 1, next_page: 2 }), given: first_page)
        Sidereal.config['sourced.store'].append(second_page)

        # Only its timeout, which Sourced refuses once it's delivered: the
        # machine has left that entry.
        expect(reacted(Import, first_page.last, import_id:).map(&:class)).to eq([TimeOutFetch])
        expect(FAKE_FREEAGENT.calls).to be_empty
        expect(reacted(Import, second_page.last, import_id:).grep(CompleteFetch).size).to eq(1)
      end
    end
  end
end
