# frozen_string_literal: true

module UI
  module Components
    # The integrations' pages: a sidebar listing the systems expenses can be
    # imported from, each with where it's at (set up, connected), and the
    # one chosen in the main area, the block's. The overview
    # (IntegrationsPage) has none chosen.
    #
    #   render Components::IntegrationsLayout.new(current: :freeagent) do
    #     ...
    #   end
    class IntegrationsLayout < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/integrations_layout.css', path: 'integrations_layout.css'

      # One system to import from: its +key+, +name+, +path+ and what it
      # does, and its status now (#status).
      Integration = ::Data.define(:key, :name, :path, :description) do
        # [label, stage] as the sidebar shows it: not set up (no app
        # credentials), not connected (no account), or connected.
        def status
          client = Sidereal.config[key.to_s]
          if !client.configured? then ['Not set up', :closed]
          elsif !client.connected? then ['Not connected', :yours]
          else ['Connected', :done]
          end
        end
      end

      # Every integration there is, in the sidebar's order.
      ALL = [
        Integration.new(key: :freeagent, name: 'FreeAgent', path: '/integrations/freeagent',
                        description: 'Import the expenses on your FreeAgent account, filed as they are there, every morning.')
      ].freeze

      # @param current [Symbol, nil] the key of the integration shown, nil for the overview
      def initialize(current: nil)
        @current = current
      end

      def view_template(&)
        div(id: 'integrations', class: 'integrations') do
          aside(class: 'integrations__nav') do
            nav(aria: { label: 'Integrations' }) do
              h2(class: 'integrations__title') { a(href: IntegrationsPage.path) { 'Integrations' } }
              ul(class: 'integrations__list') do
                ALL.each { item(it) }
              end
            end
          end
          div(class: 'integrations__main', &)
        end
      end

      private

      def item(integration)
        current = integration.key == @current
        label, stage = integration.status
        li do
          a(href: integration.path, class: ['integrations__item', ('integrations__item--current' if current)],
            aria: { current: current ? 'page' : nil }) do
            span(class: 'integrations__name') { integration.name }
            span(class: "integrations__status integrations__status--#{stage}") { label }
          end
        end
      end
    end
  end
end
