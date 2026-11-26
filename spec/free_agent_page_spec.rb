# frozen_string_literal: true

require 'rack/test'
require 'sourced/testing/rspec'

module Expenses
  RSpec.describe UI::FreeAgentPage do
    include Rack::Test::Methods
    include Sourced::Testing::RSpec

    def app = App

    let(:store) { Sidereal.config['sourced.store'] }
    let(:import_id) { Integrations::FreeAgentImport::ACCOUNT }

    # The one account's imports live in one partition: each example's go
    # when it's done.
    around do |example|
      Sidereal.config['db'].transaction(rollback: :always, auto_savepoint: true) { example.run }
    end

    def icmd(klass, **payload) = klass.new(payload: { import_id:, **payload })

    # The imports after +commands+, in the store.
    def imports!(*commands)
      decided(Integrations::FreeAgentImport, { import_id: }, *commands).tap { store.append(it) }
    end

    def page
      get '/integrations/freeagent'
      last_response.body
    end

    it 'says how to set it up, with the redirect URI to give FreeAgent, before it is' do
      FAKE_FREEAGENT.configured = false

      expect(page).to include('FreeAgent Developer Dashboard', 'http://example.org/integrations/freeagent/callback',
                              'FREEAGENT_CLIENT_ID')
      expect(last_response.body).not_to include('Connect FreeAgent', 'Import now')
    end

    it 'offers to connect an account, once set up' do
      FAKE_FREEAGENT.connected = false

      expect(page).to include('Connect FreeAgent', 'href="/integrations/freeagent/connect"')
      expect(last_response.body).not_to include('Import now')
    end

    it 'offers the first import, once connected' do
      expect(page).to include('Connected', 'None yet', 'Everything', 'Import now', 'freeagent_imports.sync_freeagent')
    end

    it 'shows the last import, how many it found new or changed, and where the next starts' do
      imports!(icmd(Integrations::FreeAgentImport::SyncFreeAgent),
               icmd(Integrations::FreeAgentImport::CompleteFetch, page: 1, count: 3, fresh: 3, latest_updated_at: Time.utc(2026, 11, 20, 10)))

      expect(page).to include('Waiting for the next import', ': 3 new or changed<', 'Changes since 20 Nov 2026', 'Import now')
    end

    it 'says which it read again, and when none was new or changed' do
      sync = Integrations::FreeAgentImport::SyncFreeAgent
      fetched = Integrations::FreeAgentImport::CompleteFetch
      imports!(icmd(sync), icmd(fetched, page: 1, count: 3, fresh: 1, latest_updated_at: Time.utc(2026, 11, 20, 10)))
      expect(page).to include(': 1 new or changed (2 read again)')
    end

    it 'says how many a run recorded before it counted them imported' do
      import = Integrations::FreeAgentImport
      history = decided(import, { import_id: }, icmd(import::SyncFreeAgent),
                        icmd(import::CompleteFetch, page: 1, count: 2, latest_updated_at: Time.utc(2026, 11, 20, 10)))
      # As stored before +fresh+ was counted: none on its events.
      old = history.map do |msg|
        next msg unless msg.is_a?(import::PageFetched) || msg.is_a?(import::SyncCompleted)

        msg.class.new(**msg.to_h, payload: msg.payload.to_h.except(:fresh))
      end
      store.append(old)

      expect(page).to include(': 2 imported<')
    end

    it 'shows the last failure, and still offers an import' do
      imports!(icmd(Integrations::FreeAgentImport::SyncFreeAgent), icmd(Integrations::FreeAgentImport::FailFetch, reason: 'FreeAgent could not be reached'))

      expect(page).to include('The last import failed', 'Last failure', 'FreeAgent could not be reached', 'Import now')
    end

    it 'offers no import while one is running' do
      imports!(icmd(Integrations::FreeAgentImport::SyncFreeAgent))

      expect(page).to include('Importing… 0 so far')
      expect(last_response.body).not_to include('Import now')
    end

    it 'follows the imports’ channel' do
      expect(stream_channels(page)).to eq(['freeagent_imports.freeagent', 'system.>'])
    end

    it 'starts an import when asked' do
      post '/commands', { command: { type: 'freeagent_imports.sync_freeagent', _cid: 'x', payload: { import_id: } } },
           'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'

      synced = store.read(Sourced::Selector[Integrations::FreeAgentImport::SyncFreeAgent].by(:import_id).bind(import_id:)).messages
      expect(synced.size).to eq(1)
    end

    describe 'connecting' do
      def connect_state
        get '/integrations/freeagent/connect'
        URI.decode_www_form(URI(last_response['Location']).query).to_h.fetch('state')
      end

      it 'is not found before it is set up' do
        FAKE_FREEAGENT.configured = false
        get '/integrations/freeagent/connect'

        expect(last_response.status).to eq(404)
      end

      it 'sends the browser to FreeAgent, with a state and where to come back to' do
        get '/integrations/freeagent/connect'
        query = URI.decode_www_form(URI(last_response['Location']).query).to_h

        expect(last_response.status).to eq(303)
        expect(last_response['Location']).to start_with('https://api.freeagent.test/v2/approve_app')
        expect(query).to include('redirect_uri' => 'http://example.org/integrations/freeagent/callback')
        expect(query['state']).to match(/\A\h{32}\z/)
      end

      it 'connects with the code FreeAgent sends back, then shows the page' do
        state = connect_state
        get '/integrations/freeagent/callback', code: 'abc', state: state

        expect(last_response.status).to eq(303)
        expect(last_response['Location']).to eq('/integrations/freeagent')
        expect(FAKE_FREEAGENT.connects).to eq([{ code: 'abc', redirect_uri: 'http://example.org/integrations/freeagent/callback' }])
      end

      it 'connects once per state' do
        state = connect_state
        get '/integrations/freeagent/callback', code: 'abc', state: state
        get '/integrations/freeagent/callback', code: 'abc', state: state

        expect(FAKE_FREEAGENT.connects.size).to eq(1)
        expect(last_response['Location']).to include('error=')
      end

      it 'refuses a callback with another state, or none' do
        connect_state
        get '/integrations/freeagent/callback', code: 'abc', state: 'forged'

        expect(last_response['Location']).to start_with('/integrations/freeagent?error=')
        expect(FAKE_FREEAGENT.connects).to be_empty

        clear_cookies
        get '/integrations/freeagent/callback', code: 'abc', state: 'whatever'
        expect(last_response['Location']).to start_with('/integrations/freeagent?error=')
        expect(FAKE_FREEAGENT.connects).to be_empty
      end

      it 'says why when FreeAgent refused, or the code was' do
        state = connect_state
        get '/integrations/freeagent/callback', error: 'access_denied', state: state
        expect(FAKE_FREEAGENT.connects).to be_empty
        follow_redirect!
        expect(last_response.body).to include('FreeAgent didn’t connect: access_denied')

        FAKE_FREEAGENT.connect_error = Integrations::FreeAgent::Error.new('FreeAgent refused the connection: connect it again')
        state = connect_state
        get '/integrations/freeagent/callback', code: 'expired', state: state
        follow_redirect!
        expect(last_response.body).to include('FreeAgent refused the connection: connect it again')
      end
    end
  end
end
