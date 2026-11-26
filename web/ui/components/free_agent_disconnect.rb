# frozen_string_literal: true

module UI
  module Components
    # Disconnecting FreeAgent, at the bottom of its page while it's
    # connected: folded away, so it takes two clicks, with what it does and
    # doesn't. Its handler forgets the tokens FreeAgent issued
    # (Integrations::FreeAgent::Client#disconnect) and reloads the page,
    # which offers to connect again.
    #
    # What's imported stays; the daily import is skipped while it's
    # disconnected (Integrations::FreeAgentImport); connecting again carries
    # on from where the last import finished.
    class FreeAgentDisconnect < Sidereal::Components::BaseComponent
      # Web only: never stored itself.
      DisconnectFreeAgent = Sidereal::Message.define('web.disconnect_freeagent')

      handle DisconnectFreeAgent do |_cmd|
        Sidereal.config['freeagent'].disconnect
        browser.redirect FreeAgentPage.path
      end

      def view_template
        details(class: 'filed__edit') do
          summary { 'Disconnect FreeAgent' }
          p(class: 'filed__note') do
            plain 'This app stops importing from your FreeAgent account. The expenses already imported stay, '
            plain 'and connecting again picks up where the last import finished. '
            plain 'FreeAgent still lists this app as allowed: remove it there too to revoke its access.'
          end
          command DisconnectFreeAgent, class: 'actions' do
            button(type: :submit, class: 'button') { 'Disconnect' }
          end
        end
      end
    end
  end
end
