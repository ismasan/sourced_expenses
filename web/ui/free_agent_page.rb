# frozen_string_literal: true

module UI
  # FreeAgent, as a source of expenses, among the integrations
  # (Components::IntegrationsLayout): how to set it up, connecting this app
  # to an account (App's /integrations/freeagent/connect and callback
  # routes), and the imports (Integrations::FreeAgentImport): the last run,
  # and a button to start one. Live: it follows the imports' events.
  class FreeAgentPage < Page
    path '/integrations/freeagent'
    # Why connecting failed, from the callback.
    query_schema error?: Types::String.nullable

    I = Integrations::FreeAgentImport

    on I

    with_machine { @import }

    def channel_names = ["freeagent_imports.#{channel_segment(I::ACCOUNT)}", *SYSTEM_CHANNELS]

    def self.load(params, _ctx)
      history = MachineHistory.load(I, I::ACCOUNT)
      new(Sidereal.config['freeagent'], history.machine, error: params[:error])
    end

    def initialize(client, import, error: nil)
      @client = client
      @import = import
      @run = import.context
      @error = error
    end

    def view_template
      render Components::IntegrationsLayout.new(current: :freeagent) do
        div(id: 'freeagent-page', class: 'record-page') do
          header(class: 'record-page__header') do
            h1(class: 'record-page__title') { 'FreeAgent' }
          end
          div(class: 'record-page__panel') do
            p(class: 'reason') { @error } if @error

            if !@client.configured? then render_setup
            elsif !@client.connected? then render_connect
            else render_imports
            end
          end
        end
      end
    end

    private

    def render_setup
      p(class: 'panel-lead') { 'Import your FreeAgent expenses. First, give this app access to FreeAgent’s API:' }
      ol do
        li do
          plain 'Create an app in the '
          a(href: 'https://dev.freeagent.com', target: '_blank', rel: 'noopener') { 'FreeAgent Developer Dashboard' }
          plain ', with this redirect URI: '
          code { App.freeagent_redirect_uri(base_url) }
        end
        li { 'Put its OAuth identifier and secret in .env, as FREEAGENT_CLIENT_ID and FREEAGENT_CLIENT_SECRET (and FREEAGENT_SANDBOX=1 for a sandbox account).' }
        li { 'Restart the app, and come back here to connect your account.' }
      end
    end

    def render_connect
      p(class: 'panel-lead') do
        plain "Connect your FreeAgent #{'sandbox ' if @client.sandbox?}account, to import its expenses."
      end
      div(class: 'actions') do
        a(href: '/integrations/freeagent/connect', class: 'button button--primary') { 'Connect FreeAgent' }
      end
    end

    def render_imports
      p(class: 'panel-lead') do
        plain "Connected#{' to the sandbox' if @client.sandbox?}. Each import brings in the expenses created or changed "
        plain 'on FreeAgent since the last one, filed as they are there.'
      end
      dl(class: 'filed') do
        dt { 'Now' }
        dd { status }
        dt { 'Last import' }
        dd do
          if @run[:synced_at]
            plain "#{@run[:synced_at].getlocal.strftime('%-d %b %Y, %H:%M')}: #{last_import_counts}"
          else
            span(class: 'filed__note') { 'None yet' }
          end
        end
        dt { 'Next one reads' }
        dd { @run[:cursor] ? "Changes since #{@run[:cursor].getlocal.strftime('%-d %b %Y, %H:%M')}" : 'Everything' }
        if (failure = @run[:failure])
          dt { 'Last failure' }
          dd { failure[:reason] }
        end
      end
      return unless @import.available_commands.include?(I::SyncFreeAgent)

      command I::SyncFreeAgent, class: 'actions' do |f|
        f.payload_fields(import_id: I::ACCOUNT)
        button(type: :submit, class: 'button button--primary') { 'Import now' }
      end
    end

    # New or changed, and read again (each run reads from a little before
    # where the last one finished: Integrations::FreeAgentImport::OVERLAP).
    # A run recorded before that was counted says how many it imported.
    def last_import_counts
      count, fresh = @run.values_at(:synced_count, :synced_fresh)
      return "#{count} imported" if fresh.nil?

      again = count - fresh
      text = fresh.zero? ? 'none new or changed' : "#{fresh} new or changed"
      again.positive? ? "#{text} (#{again} read again)" : text
    end

    def status
      paths = @import.machine.paths
      if paths.include?('fetching') then "Importing… #{@run[:count]} so far"
      elsif paths.include?('failed') then 'The last import failed'
      else 'Waiting for the next import'
      end
    end

    def base_url = context.request.base_url
  end
end
