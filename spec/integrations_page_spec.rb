# frozen_string_literal: true

require 'rack/test'

# The integrations' pages (UI::IntegrationsPage, and each integration's own,
# in UI::Components::IntegrationsLayout): the top nav's Integrations, the
# sidebar listing them with where each is at, and the one chosen beside it.
RSpec.describe UI::IntegrationsPage do
  include Rack::Test::Methods

  def app = App

  def body(path)
    get path
    expect(last_response.status).to eq(200)
    last_response.body
  end

  # The sidebar's HTML, and the main area's.
  def sidebar(html) = html[%r{<aside class="integrations__nav">.*?</aside>}m]
  def main(html) = html[%r{<div class="integrations__main">.*}m]

  it 'is the top nav’s Integrations, current on an integration’s page too' do
    %w[/integrations /integrations/freeagent].each do |path|
      expect(body(path)).to match(%r{<a href="/integrations" class="topnav__link" aria-current="page">Integrations</a>}), path
    end
    expect(body('/')).not_to match(%r{<a href="/integrations/freeagent" class="topnav__link"})
  end

  it 'lists the integrations with where each is at, and a card for each, none chosen' do
    html = body('/integrations')

    expect(sidebar(html)).to include('href="/integrations/freeagent"', '>FreeAgent<', 'integrations__status--done">Connected<')
    expect(sidebar(html)).not_to include('aria-current')
    expect(main(html)).to include('integrations__card', '>FreeAgent<', 'every morning')
  end

  it 'shows an integration beside the list, marked as the one chosen' do
    html = body('/integrations/freeagent')

    expect(sidebar(html)).to match(/integrations__item--current" aria-current="page">.*FreeAgent/m)
    expect(main(html)).to include('record-page__title">FreeAgent<', 'Import now', 'filed as they are there')
  end

  it 'says where each is at: not set up, not connected, connected' do
    FAKE_FREEAGENT.connected = false
    expect(sidebar(body('/integrations'))).to include('integrations__status--yours">Not connected<')

    FAKE_FREEAGENT.configured = false
    expect(sidebar(body('/integrations'))).to include('integrations__status--closed">Not set up<')
  end
end
