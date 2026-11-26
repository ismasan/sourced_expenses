# frozen_string_literal: true

require 'json'

RSpec.describe Integrations::FreeAgent::Client do
  let(:db) { Sidereal.config['db'] }
  let(:tokens) { Integrations::FreeAgent::Tokens.new(db:) }
  let(:client) { described_class.new(client_id: 'app-id', client_secret: 'app-secret', tokens:) }
  let(:http) { instance_double(Net::HTTP) }
  # Every Net::HTTP.start: [host, use_ssl].
  let(:connections) { [] }

  before do
    db[:oauth_tokens].delete
    allow(Net::HTTP).to receive(:start) do |host, _port, use_ssl:, **, &block|
      connections << [host, use_ssl]
      block.call(http)
    end
  end

  after { db[:oauth_tokens].delete }

  def response(klass, code, body = '', **headers)
    klass.new('1.1', code, 'msg').tap do |r|
      headers.each { |name, value| r[name.to_s.tr('_', '-')] = value }
      allow(r).to receive(:body).and_return(body)
    end
  end

  def ok(body, **headers) = response(Net::HTTPOK, '200', JSON.generate(body), **headers)

  def token_answer(access: 'new-access', refresh: 'new-refresh')
    { 'access_token' => access, 'token_type' => 'bearer', 'expires_in' => 3600, 'refresh_token' => refresh,
      'refresh_token_expires_in' => 631_151_957 }
  end

  # Connected, with an access token good for an hour, or one +expired+.
  def connect!(expired: false, now: Time.now)
    tokens.save({ 'access_token' => 'old-access', 'refresh_token' => 'old-refresh', 'expires_in' => expired ? 0 : 3600 },
                now:)
  end

  # The form posted to the token endpoint, and its Basic auth.
  def token_posts
    posts = []
    allow(http).to receive(:request) do |request|
      posts << { path: request.path, form: URI.decode_www_form(request.body).to_h, auth: request['Authorization'] }
      @token_responses.shift
    end
    posts
  end

  describe Integrations::FreeAgent::Tokens do
    it 'keeps one set of tokens, the latest' do
      now = Time.utc(2026, 11, 26, 9)
      expect(tokens.load).to be_nil

      tokens.save({ 'access_token' => 'a1', 'refresh_token' => 'r1', 'expires_in' => 3600 }, now:)
      tokens.save({ 'access_token' => 'a2', 'refresh_token' => 'r2', 'expires_in' => 3600 }, now:)

      expect(db[:oauth_tokens].count).to eq(1)
      expect(tokens.load).to have_attributes(access_token: 'a2', refresh_token: 'r2')
      expect(tokens.load.expires_at.to_i).to eq((now + 3600).to_i)
    end

    it 'counts a token as expired a minute before it is' do
      token = Integrations::FreeAgent::Tokens::Token.new(access_token: 'a', refresh_token: 'r', expires_at: Time.utc(2026, 1, 1, 12))

      expect(token.expired?(Time.utc(2026, 1, 1, 11, 58))).to be(false)
      expect(token.expired?(Time.utc(2026, 1, 1, 11, 59, 30))).to be(true)
    end

    it 'forgets them on clear' do
      connect!
      tokens.clear

      expect(tokens.load).to be_nil
    end
  end

  describe 'connecting' do
    it 'is configured with an identifier and a secret, and connected with tokens' do
      expect(client).to be_configured
      expect(described_class.new(client_id: '', client_secret: 'x', tokens:)).not_to be_configured
      expect(described_class.new(client_id: nil, client_secret: nil, tokens:)).not_to be_configured
      expect(client).not_to be_connected
      connect!
      expect(client).to be_connected
    end

    it 'sends a person to FreeAgent to let it read their account, the sandbox’s or not' do
      url = client.authorize_url(redirect_uri: 'http://localhost:9292/integrations/freeagent/callback', state: 'a b')
      uri = URI(url)

      expect(url).to start_with('https://api.freeagent.com/v2/approve_app?')
      expect(URI.decode_www_form(uri.query).to_h).to eq(
        'client_id' => 'app-id', 'response_type' => 'code', 'state' => 'a b',
        'redirect_uri' => 'http://localhost:9292/integrations/freeagent/callback'
      )
      expect(uri.query).to include('redirect_uri=http%3A%2F%2Flocalhost%3A9292%2Fintegrations%2Ffreeagent%2Fcallback')

      sandbox = described_class.new(client_id: 'app-id', client_secret: 'app-secret', tokens:, sandbox: true)
      expect(sandbox).to be_sandbox
      expect(sandbox.authorize_url(redirect_uri: 'x', state: 's')).to start_with('https://api.sandbox.freeagent.com/v2/approve_app?')
    end

    it 'trades the code for tokens, with the app’s identifier and secret, and keeps them' do
      @token_responses = [ok(token_answer)]
      posts = token_posts

      client.connect(code: 'the-code', redirect_uri: 'http://localhost:9292/cb')

      expect(posts).to eq([{
                            path: '/v2/token_endpoint',
                            form: { 'grant_type' => 'authorization_code', 'code' => 'the-code', 'redirect_uri' => 'http://localhost:9292/cb' },
                            auth: "Basic #{['app-id:app-secret'].pack('m0')}"
                          }])
      expect(tokens.load).to have_attributes(access_token: 'new-access', refresh_token: 'new-refresh')
      expect(connections).to eq([['api.freeagent.com', true]])
    end

    it 'says so when FreeAgent refuses the code' do
      @token_responses = [response(Net::HTTPBadRequest, '400', '{"error":"invalid_grant"}')]
      token_posts

      expect { client.connect(code: 'stale', redirect_uri: 'x') }
        .to raise_error(Integrations::FreeAgent::Error, 'FreeAgent refused the connection: connect it again')
      expect(tokens.load).to be_nil
    end
  end

  describe '#expenses' do
    let(:expense) { { 'url' => 'https://api.freeagent.com/v2/expenses/1', 'gross_value' => '-24.0' } }

    it 'reads a page of expenses changed since a time, with its access token' do
      connect!
      asked = nil
      allow(http).to receive(:get) do |path, headers|
        asked = [path, headers]
        ok({ 'expenses' => [expense] })
      end

      page = client.expenses(updated_since: Time.new(2026, 11, 20, 11, 0, 0, '+01:00'), page: 2)

      expect(page).to eq(described_class::Page.new(expenses: [expense], next_page: nil))
      path, headers = asked
      expect(path).to start_with('/v2/expenses?')
      expect(URI.decode_www_form(URI(path).query).to_h)
        .to eq('page' => '2', 'per_page' => '100', 'updated_since' => '2026-11-20T10:00:00Z')
      expect(headers).to include('Authorization' => 'Bearer old-access', 'Accept' => 'application/json',
                                 'User-Agent' => 'sourced-expenses')
    end

    it 'reads every expense without a time' do
      connect!
      allow(http).to receive(:get).and_return(ok({ 'expenses' => [] }))

      client.expenses

      expect(http).to have_received(:get).with('/v2/expenses?page=1&per_page=100', anything)
    end

    it 'finds the next page in the Link header' do
      connect!
      link = '<https://api.freeagent.com/v2/expenses?page=3&per_page=100>; rel="next", ' \
             '<https://api.freeagent.com/v2/expenses?page=9&per_page=100>; rel="last"'
      allow(http).to receive(:get).and_return(ok({ 'expenses' => [expense] }, Link: link))

      expect(client.expenses(page: 2).next_page).to eq(3)
    end

    it 'refreshes an expired token first, keeping the new refresh token' do
      connect!(expired: true)
      @token_responses = [ok(token_answer(access: 'fresh', refresh: 'rotated'))]
      posts = token_posts
      allow(http).to receive(:get).and_return(ok({ 'expenses' => [] }))

      client.expenses

      expect(posts.map { it[:form] }).to eq([{ 'grant_type' => 'refresh_token', 'refresh_token' => 'old-refresh' }])
      expect(http).to have_received(:get).with(anything, hash_including('Authorization' => 'Bearer fresh'))
      expect(tokens.load).to have_attributes(access_token: 'fresh', refresh_token: 'rotated')
    end

    it 'refreshes and tries once more when the token is refused' do
      connect!
      @token_responses = [ok(token_answer(access: 'fresh', refresh: 'rotated'))]
      posts = token_posts
      answers = [response(Net::HTTPUnauthorized, '401'), ok({ 'expenses' => [expense] })]
      allow(http).to receive(:get) { answers.shift }

      expect(client.expenses.expenses).to eq([expense])
      expect(posts.size).to eq(1)
      expect(http).to have_received(:get).with(anything, hash_including('Authorization' => 'Bearer fresh'))
    end

    it 'gives up when it is refused again' do
      connect!
      @token_responses = [ok(token_answer)]
      token_posts
      allow(http).to receive(:get).and_return(response(Net::HTTPUnauthorized, '401'))

      expect { client.expenses }.to raise_error(Integrations::FreeAgent::Error, 'FreeAgent refused the access token: connect it again')
      expect(http).to have_received(:get).twice
    end

    it 'says it isn’t connected without tokens' do
      expect { client.expenses }.to raise_error(Integrations::FreeAgent::Error, 'FreeAgent isn’t connected')
    end

    it 'says what went wrong, for a person to read' do
      connect!
      {
        response(Net::HTTPTooManyRequests, '429', '', Retry_After: '30') => 'FreeAgent is rate limiting requests: try again in 30 seconds',
        response(Net::HTTPTooManyRequests, '429') => 'FreeAgent is rate limiting requests: try again in 60 seconds',
        response(Net::HTTPInternalServerError, '500') => 'FreeAgent answered 500',
        response(Net::HTTPOK, '200', '<html>') => 'FreeAgent sent an answer that could not be read'
      }.each do |answer, message|
        allow(http).to receive(:get).and_return(answer)
        expect { client.expenses }.to raise_error(Integrations::FreeAgent::Error, message)
      end
    end

    it 'says it couldn’t reach FreeAgent' do
      connect!
      [Errno::ECONNREFUSED, SocketError, Net::OpenTimeout].each do |error|
        allow(Net::HTTP).to receive(:start).and_raise(error)
        expect { client.expenses }.to raise_error(Integrations::FreeAgent::Error, 'FreeAgent could not be reached'), error.name
      end
    end
  end

  describe '#web_url' do
    it 'is the company’s own site, from its subdomain, read once' do
      connect!
      allow(http).to receive(:get).and_return(ok({ 'company' => { 'subdomain' => 'acme', 'name' => 'Acme Ltd' } }))

      expect(client.web_url).to eq('https://acme.freeagent.com')
      client.web_url
      expect(http).to have_received(:get).once.with('/v2/company', anything)
    end
  end

  describe '#categories' do
    def category(code, name)
      { 'url' => "https://api.freeagent.com/v2/categories/#{code}", 'nominal_code' => code, 'description' => name }
    end

    it 'reads every group of categories, by url, once' do
      connect!
      allow(http).to receive(:get).and_return(ok({
                                                   'admin_expenses_categories' => [category('285', 'Accommodation and Meals')],
                                                   'cost_of_sales_categories' => [category('101', 'Cost of Sales')],
                                                   'income_categories' => [],
                                                   'general_categories' => [category('602', 'Capital Assets')]
                                                 }))

      categories = client.categories
      client.categories

      expect(categories.keys).to contain_exactly(*%w[285 101 602].map { "https://api.freeagent.com/v2/categories/#{it}" })
      expect(categories['https://api.freeagent.com/v2/categories/285'])
        .to eq(described_class::Category.new(url: 'https://api.freeagent.com/v2/categories/285', nominal_code: '285',
                                             description: 'Accommodation and Meals'))
      expect(http).to have_received(:get).once.with('/v2/categories', anything)
    end
  end
end
