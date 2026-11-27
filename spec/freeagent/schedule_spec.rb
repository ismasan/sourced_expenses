# frozen_string_literal: true

# The daily FreeAgent import, as App declares it (`schedule 'FreeAgent
# import'`), fired by a scheduler of its own with a clock of the spec's:
# what it appends to the store, and when.
RSpec.describe 'The daily FreeAgent import' do
  let(:import) { FreeAgent::Import }

  # What a scheduler appends, instead of the store.
  let(:store) do
    Class.new do
      attr_reader :appended

      def initialize = @appended = []
      def append(message) = @appended << message
    end.new
  end

  let(:declared) { Sidereal.scheduler.schedules.find { it.name == 'FreeAgent import' } }

  # App's schedule, step for step, in a scheduler starting at +start+.
  def scheduler(start)
    Sidereal::Scheduler.new(baseline: start, store:).schedule(declared.name) do |sc|
      declared.steps.each { |step| sc.at(step.expression, step.klass, **step.payload) }
    end
  end

  it 'is declared' do
    expect(declared).not_to be_nil
  end

  it 'starts an import of the FreeAgent account every day at 8am, and at no other time' do
    day = Time.local(2026, 11, 27)
    sc = scheduler(day + (7 * 3600) + (59 * 60))

    sc.tick(day + (7 * 3600) + (59 * 60) + 30) # 07:59:30
    expect(store.appended).to be_empty

    sc.tick(day + (8 * 3600) + 1)                 # 08:00:01
    sc.tick(day + (8 * 3600) + (30 * 60))         # 08:30
    sc.tick(day + (23 * 3600))                    # 23:00
    expect(store.appended.size).to eq(1)

    sc.tick(day + (32 * 3600) + 5)                # the next day, 08:00:05
    expect(store.appended.size).to eq(2)

    expect(store.appended).to all(be_a(import::SyncFreeAgent))
    expect(store.appended.map { it.payload.to_h }).to all(eq(import_id: import::ACCOUNT, since: nil))
    expect(store.appended.first.metadata).to include(schedule_name: 'FreeAgent import')
  end
end
