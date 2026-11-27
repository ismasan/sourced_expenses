# frozen_string_literal: true

require 'sidereal/cli'
require_relative '../cli/expenses'

RSpec.describe CLI::Expenses::Import do
  let(:store) { Sidereal.config['sourced.store'] }
  let(:out) { StringIO.new }

  # The app is built already, by spec_helper.
  before { allow(Sidereal::CLI).to receive(:boot_app!) }

  # Every import is the one account's partition: each example's are rolled
  # back, as the FreeAgent page spec's are.
  around do |example|
    Sidereal.config['db'].transaction(rollback: :always, auto_savepoint: true) { example.run }
  end

  def run(*arguments) = described_class.new(arguments, output: out).call

  def syncs = store.read_all(limit: 10_000).to_a.select { it.is_a?(FreeAgent::Import::SyncFreeAgent) }

  it 'starts an import, saying where to follow it' do
    expect { run('freeagent') }.to change { syncs.size }.by(1)

    expect(syncs.last.payload.to_h).to eq(import_id: 'freeagent', since: nil)
    expect(out.string).to include('Importing from FreeAgent', 'http://localhost:9292/integrations/freeagent')
  end

  it 'backfills from the day --since gives' do
    run('--since', '2026-01-15', 'freeagent')

    expect(syncs.last.payload.since).to eq(Time.utc(2026, 1, 15))
    expect(out.string).to include('since 2026-01-15')
  end

  it 'lists FreeAgent’s categories and which of ours each is, importing nothing' do
    url = 'https://api.freeagent.com/v2/categories/'
    FAKE_FREEAGENT.categories = {
      "#{url}285" => FreeAgent::Client::Category.new(url: "#{url}285", nominal_code: '285', description: 'Accommodation and Meals'),
      "#{url}999" => FreeAgent::Client::Category.new(url: "#{url}999", nominal_code: '999', description: 'Widgets')
    }

    expect { run('--categories', 'freeagent') }.not_to(change { syncs.size })
    expect(out.string).to match(/285\s+Accommodation and Meals\s+Accommodation and Meals/)
    expect(out.string).to match(/999\s+Widgets\s+its own \(widgets\)/)
  end

  it 'says what’s missing, starting nothing' do
    FAKE_FREEAGENT.connected = false
    expect { run('freeagent') }.to raise_error(Sidereal::CLI::Error, %r{isn’t connected: connect it at http://localhost:9292/integrations/freeagent})

    FAKE_FREEAGENT.configured = false
    expect { run('freeagent') }.to raise_error(Sidereal::CLI::Error, /isn’t set up/)
    expect { run('xero') }.to raise_error(Sidereal::CLI::Error, /one of: freeagent/)
    expect { run('--since', 'yesterday', 'freeagent') }.to raise_error(Sidereal::CLI::Error, /isn't a date/)
    expect(syncs).to be_empty
  end
end
