# frozen_string_literal: true

module FreeAgent
  # Imports a FreeAgent account's expenses, a run at a time: each run reads
  # the expenses updated there since the last run finished, a page at a
  # time, and imports each into an Expense (ImportExpense, under
  # freeagent-<its id there>). `bin/sid expenses import freeagent`, or the
  # FreeAgent page's button, starts a run.
  #
  #   initial, idle, failed ─SyncFreeAgent─▶ fetching ─CompleteFetch [next page]─▶ fetching
  #                                                   ├CompleteFetch [last page]─▶ idle
  #                                                   ├FailFetch─────────────────▶ failed
  #                                                   └after 5m: TimeOutFetch────▶ failed
  #
  # Entering fetching reads a page (the `freeagent` client), dispatches an
  # ImportExpense for each expense on it (ExpenseMapping) and
  # CompleteFetch with how far it got, or FailFetch with why not, all in
  # one reaction. The machine's own consumer group makes the call: a slow
  # FreeAgent holds up nothing else.
  #
  # Where the next run starts (+cursor+) moves only when a run finishes: to
  # the latest +updated_at+ it read. A run that fails starts again from the
  # same place, and one that reads nothing leaves it as it was. Reading an
  # expense again is harmless: importing it again changes nothing.
  #
  # Its events record each run: SyncStarted (from when), PageFetched,
  # SyncCompleted (the new cursor), SyncFailed. FreeAgent's tokens are never
  # in them: they're Tokens'.
  class Import < Sourced::Machine
    extend Sidereal::Deps

    partition_by import_id: Types::String.present
    consumer_group 'freeagent.import'
    message_prefix 'freeagent_imports'

    dep :freeagent, :db, 'expenses.filing_country' => 'filing_country'

    # The one account there is, for now: its partition.
    ACCOUNT = 'freeagent'

    # The name of App's schedule that starts an import every morning, for
    # the FreeAgent page to say when.
    SCHEDULE = 'FreeAgent import'

    # How long a page may take, its retries included.
    FETCH_TIMEOUT = '5m'

    # Each run reads from this long before where the last one finished:
    # whether FreeAgent's updated_since includes the time itself isn't
    # documented, and importing an expense again changes nothing.
    OVERLAP = 60

    # ---- States ----

    Fetching = State(:fetching)
    Idle = State(:idle)
    Failed = State(:failed)

    # ---- Commands ----

    # Start a run: from +since+ (a backfill), or else from where the last
    # run finished (everything, the first time). Not while FreeAgent isn't
    # connected: there's nothing to read, so it's skipped, recording
    # nothing (the daily schedule's, before anyone connects).
    SyncFreeAgent = Command(:sync_freeagent) do
      attribute :import_id, Types::String.present
      attribute :since, Types::Time.nullable.default(nil)
    end

    # A page read: +page+'s number, how many of its expenses were imported
    # and how many skipped (mileage, or one that doesn't make an expense
    # here, such as an unknown currency), the latest +updated_at+ among
    # them, and the next page's number (nil on the last). Dispatched by
    # fetching's entry, never by a person.
    CompleteFetch = Command(:complete_fetch) do
      attribute :page, Integer
      attribute :count, Integer
      # Of +count+, how many were updated there after the last run finished:
      # new or changed. The rest are read again (see OVERLAP).
      attribute :fresh, Types::Integer.default(0)
      attribute :skipped, Types::Integer.default(0)
      attribute :latest_updated_at, Types::Time.nullable.default(nil)
      attribute :next_page, Types::Integer.nullable.default(nil)
    end

    FailFetch = Command(:fail_fetch) do
      attribute :reason, Types::String.present
    end

    # Dispatched by fetching's timer, never by a person.
    TimeOutFetch = Command(:time_out_fetch)

    # ---- Events ----

    SyncStarted = Event(:sync_started) do
      attribute :updated_since, Types::Time.nullable
    end

    # +fresh+: nil in a page recorded before it was counted.
    PageFetched = Event(:page_fetched) do
      attribute :page, Integer
      attribute :count, Integer
      attribute :fresh, Types::Integer.nullable.default(nil)
      attribute :skipped, Integer
      attribute :latest_updated_at, Types::Time.nullable
    end

    # +cursor+: where the next run starts.
    # +count+: every expense imported, read again or not; +fresh+, how many of
    # them were new or changed (nil in a run recorded before it was counted).
    SyncCompleted = Event(:sync_completed) do
      attribute :cursor, Types::Time.nullable
      attribute :count, Integer
      attribute :fresh, Types::Integer.nullable.default(nil)
    end

    SyncFailed = Event(:sync_failed) do
      attribute :reason, String
    end

    # ---- Its state ----

    # One account's imports are one partition, a run's events added to it
    # every day: a claim reads its history after the latest snapshot, stored
    # every SNAPSHOT_EVERY messages. Bump SNAPSHOT_VERSION whenever the
    # context's shape or its evolve blocks change.
    SNAPSHOT_EVERY = 100
    SNAPSHOT_VERSION = 2

    # The context (below), as a snapshot stores it: the store encodes it
    # through Plumb's JSON codec for this type, so its times are stored as
    # ISO 8601 and read back as times.
    Run = Types::Hash[
      cursor: Types::Time.nullable,
      updated_since: Types::Time.nullable,
      page: Integer,
      count: Integer,
      fresh: Integer,
      latest: Types::Time.nullable,
      fetching: Types::Boolean,
      synced_at: Types::Time.nullable,
      synced_count: Types::Integer.nullable,
      synced_fresh: Types::Integer.nullable,
      failure: Types::Hash[reason: String, at: Types::Time].nullable
    ]

    snapshot every: SNAPSHOT_EVERY, version: SNAPSHOT_VERSION, type: Run

    # +cursor+ where the next run starts; the run's +updated_since+, the
    # +page+ to read next, how many it has read (+count+) and the latest
    # +updated_at+ among them; when the last run finished, and the last
    # failure.
    context do
      { cursor: nil, updated_since: nil, page: 1, count: 0, fresh: 0, latest: nil, fetching: false,
        synced_at: nil, synced_count: nil, synced_fresh: nil, failure: nil }
    end

    evolve SyncStarted do |run, evt|
      run.merge!(updated_since: evt.payload.updated_since, page: 1, count: 0, fresh: 0, latest: nil, failure: nil)
    end

    evolve Fetching do |run, _evt|
      run[:fetching] = true
    end

    evolve PageFetched do |run, evt|
      run[:page] = evt.payload.page + 1
      run[:count] += evt.payload.count
      run[:fresh] += evt.payload.fresh || evt.payload.count
      run[:latest] = [run[:latest], evt.payload.latest_updated_at].compact.max
    end

    evolve SyncCompleted do |run, evt|
      run.merge!(cursor: evt.payload.cursor, fetching: false, synced_at: evt.created_at, synced_count: evt.payload.count,
                 synced_fresh: evt.payload.fresh)
    end

    evolve SyncFailed do |run, evt|
      run.merge!(fetching: false, failure: { reason: evt.payload.reason, at: evt.created_at })
    end

    # ---- The statechart ----

    START = proc do
      command SyncFreeAgent => Fetching | nil do |run, cmd|
        next unless freeagent.connected?

        event SyncStarted, updated_since: cmd.payload.since || (run[:cursor] && run[:cursor] - OVERLAP)
        to Fetching
      end
    end

    initial(&START)

    state Fetching do
      # Nothing if the machine has moved on since +entered+ (the page was
      # read, or the run failed: an old entry a group catching up claims).
      entry Expenses::Expense::ImportExpense | CompleteFetch | FailFetch | nil do |run, entered|
        next unless run[:fetching] && projection.current?(entered)

        import_id = entered.payload.import_id
        begin
          page = freeagent.expenses(updated_since: run[:updated_since], page: run[:page])
          # Those uploaded from here (Upload) are expenses here
          # already: left out, counted neither as imported nor as skipped.
          ours = UploadList.external_ids(db)
          theirs = page.expenses.reject { ours.include?(it['url'].to_s.split('/').last) }
          categories = theirs.empty? ? {} : freeagent.categories
          web_url = theirs.empty? ? nil : web_url()
          imported = theirs.filter_map do |expense|
            command = import_for(expense, categories, web_url)
            command && [command, Types.iso_time(expense['updated_at'])]
          end
          imported.each { |command, _| dispatch command }
          # New or changed since the last run finished (+cursor+ moves only
          # then): updated after it, or every one the first time.
          fresh = imported.count { |_, updated_at| run[:cursor].nil? || updated_at.nil? || updated_at > run[:cursor] }
          latest = page.expenses.filter_map { Types.iso_time(it['updated_at']) }.max
          dispatch CompleteFetch, import_id:, page: run[:page], count: imported.size, fresh:,
                                  skipped: theirs.size - imported.size, latest_updated_at: latest,
                                  next_page: page.next_page
        rescue Error => e
          dispatch FailFetch, import_id:, reason: e.message
        end
      end

      after(FETCH_TIMEOUT => TimeOutFetch)

      # The run's totals are taken before PageFetched: appending an event
      # evolves +run+ with it.
      command CompleteFetch => Fetching | Idle do |run, cmd|
        count = run[:count] + cmd.payload.count
        fresh = run[:fresh] + cmd.payload.fresh
        latest = [run[:latest], cmd.payload.latest_updated_at].compact.max
        cursor = run[:cursor]
        event PageFetched, cmd.payload
        if cmd.payload.next_page
          to Fetching
        else
          event SyncCompleted, cursor: latest || cursor, count: count, fresh: fresh
          to Idle
        end
      end

      command FailFetch => Failed do |_run, cmd|
        event SyncFailed, cmd.payload
      end

      command TimeOutFetch => Failed do
        event SyncFailed, reason: "Reading FreeAgent took longer than #{FETCH_TIMEOUT}"
      end
    end

    # +expense+ (FreeAgent's) as a valid ImportExpense, or nil: skipped, as
    # one that isn't an expense here, or one FreeAgent sent without what an
    # expense needs (no date, say), so it can't hold the run up.
    def import_for(expense, categories, web_url)
      payload = ExpenseMapping.payload(expense, categories:, filing_country:, web_url:) or return
      command = Expenses::Expense::ImportExpense.new(payload:)
      command if command.valid?
    rescue KeyError, ArgumentError, TypeError, Date::Error
      nil
    end

    # The company's FreeAgent site, to link each expense to its page there,
    # or nil: a link isn't worth failing the run for.
    def web_url
      freeagent.web_url
    rescue Error
      nil
    end

    state(Idle, &START)
    state(Failed, &START)
  end
end
