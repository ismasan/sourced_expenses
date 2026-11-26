# frozen_string_literal: true

module UI
  # The systems expenses can be imported from (Components::IntegrationsLayout's
  # list), each with what it does and where it's at: the sidebar's, with
  # none chosen. Choosing one opens its own page (FreeAgentPage).
  class IntegrationsPage < Page
    path '/integrations'

    def self.load(_params, _ctx) = new

    def view_template
      render Components::IntegrationsLayout.new do
        header(class: 'record-page__header') do
          h1(class: 'record-page__title') { 'Integrations' }
        end
        div(class: 'record-page__panel') do
          p(class: 'panel-lead') { 'Other systems to import expenses from. Choose one to set it up, connect it, or see its imports.' }
          ul(class: 'integrations__cards') do
            Components::IntegrationsLayout::ALL.each { card(it) }
          end
        end
      end
    end

    private

    def card(integration)
      label, stage = integration.status
      li do
        a(href: integration.path, class: 'integrations__card') do
          span(class: 'integrations__card-head') do
            span(class: 'integrations__card-name') { integration.name }
            span(class: "integrations__status integrations__status--#{stage}") { label }
          end
          p { integration.description }
        end
      end
    end
  end
end
