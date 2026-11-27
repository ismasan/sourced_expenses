# frozen_string_literal: true

require 'json'

RSpec.describe FreeAgent::Client do
  let(:db) { Sidereal.config['db'] }
  let(:tokens) { FreeAgent::Tokens.new(db:) }
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

  # Every request is made with Net::HTTP#request: the token endpoint's
  # posts, answered from @token_responses, and the API's, recorded in
  # +api_calls+ and answered by #answer.
  let(:token_calls) { [] }
  let(:api_calls) { [] }

  before do
    allow(http).to receive(:request) do |request|
      if request.path.end_with?('/token_endpoint')
        token_calls << { path: request.path, form: URI.decode_www_form(request.body).to_h, auth: request['Authorization'] }
        @token_responses.shift
      else
        api_calls << request
        @api_answer.respond_to?(:call) ? @api_answer.call(request) : @api_answer
      end
    end
  end

  # What the API answers: +response+ every time, or the block's for each request.
  def answer(response = nil, &block) = @api_answer = block || response

  # The form posted to the token endpoint, and its Basic auth.
  def token_posts = token_calls

  # An API request as [its method, its path].
  def call(request) = [request.method, request.path]

  describe FreeAgent::Tokens do
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
      token = FreeAgent::Tokens::Token.new(access_token: 'a', refresh_token: 'r', expires_at: Time.utc(2026, 1, 1, 12))

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
        .to raise_error(FreeAgent::Error, 'FreeAgent refused the connection: connect it again')
      expect(tokens.load).to be_nil
    end
  end

  describe '#expenses' do
    let(:expense) { { 'url' => 'https://api.freeagent.com/v2/expenses/1', 'gross_value' => '-24.0' } }

    it 'reads a page of expenses changed since a time, with its access token' do
      connect!
      answer ok({ 'expenses' => [expense] })

      page = client.expenses(updated_since: Time.new(2026, 11, 20, 11, 0, 0, '+01:00'), page: 2)

      expect(page).to eq(described_class::Page.new(expenses: [expense], next_page: nil))
      request = api_calls.last
      expect(request.method).to eq('GET')
      expect(request.path).to start_with('/v2/expenses?')
      expect(URI.decode_www_form(URI(request.path).query).to_h)
        .to eq('page' => '2', 'per_page' => '100', 'updated_since' => '2026-11-20T10:00:00Z')
      expect([request['Authorization'], request['Accept'], request['User-Agent']])
        .to eq(['Bearer old-access', 'application/json', 'sourced-expenses'])
    end

    it 'reads every expense without a time' do
      connect!
      answer ok({ 'expenses' => [] })

      client.expenses

      expect(api_calls.map { call(it) }).to eq([['GET', '/v2/expenses?page=1&per_page=100']])
    end

    it 'finds the next page in the Link header' do
      connect!
      link = '<https://api.freeagent.com/v2/expenses?page=3&per_page=100>; rel="next", ' \
             '<https://api.freeagent.com/v2/expenses?page=9&per_page=100>; rel="last"'
      answer ok({ 'expenses' => [expense] }, Link: link)

      expect(client.expenses(page: 2).next_page).to eq(3)
    end

    it 'refreshes an expired token first, keeping the new refresh token' do
      connect!(expired: true)
      @token_responses = [ok(token_answer(access: 'fresh', refresh: 'rotated'))]
      posts = token_posts
      answer ok({ 'expenses' => [] })

      client.expenses

      expect(posts.map { it[:form] }).to eq([{ 'grant_type' => 'refresh_token', 'refresh_token' => 'old-refresh' }])
      expect(api_calls.map { it['Authorization'] }).to eq(['Bearer fresh'])
      expect(tokens.load).to have_attributes(access_token: 'fresh', refresh_token: 'rotated')
    end

    it 'refreshes and tries once more when the token is refused' do
      connect!
      @token_responses = [ok(token_answer(access: 'fresh', refresh: 'rotated'))]
      posts = token_posts
      answers = [response(Net::HTTPUnauthorized, '401'), ok({ 'expenses' => [expense] })]
      answer { answers.shift }

      expect(client.expenses.expenses).to eq([expense])
      expect(posts.size).to eq(1)
      expect(api_calls.map { it['Authorization'] }).to eq(['Bearer old-access', 'Bearer fresh'])
    end

    it 'gives up when it is refused again' do
      connect!
      @token_responses = [ok(token_answer)]
      token_posts
      answer response(Net::HTTPUnauthorized, '401')

      expect { client.expenses }.to raise_error(FreeAgent::Error, 'FreeAgent refused the access token: connect it again')
      expect(api_calls.size).to eq(2)
    end

    it 'says it isn’t connected without tokens' do
      expect { client.expenses }.to raise_error(FreeAgent::Error, 'FreeAgent isn’t connected')
    end

    it 'says what went wrong, for a person to read' do
      connect!
      {
        response(Net::HTTPTooManyRequests, '429', '', Retry_After: '30') => 'FreeAgent is rate limiting requests: try again in 30 seconds',
        response(Net::HTTPTooManyRequests, '429') => 'FreeAgent is rate limiting requests: try again in 60 seconds',
        response(Net::HTTPInternalServerError, '500') => 'FreeAgent answered 500',
        response(Net::HTTPOK, '200', '<html>') => 'FreeAgent sent an answer that could not be read'
      }.each do |answer, message|
        answer(answer)
        expect { client.expenses }.to raise_error(FreeAgent::Error, message)
      end
    end

    it 'says it couldn’t reach FreeAgent' do
      connect!
      [Errno::ECONNREFUSED, SocketError, Net::OpenTimeout].each do |error|
        allow(Net::HTTP).to receive(:start).and_raise(error)
        expect { client.expenses }.to raise_error(FreeAgent::Error, 'FreeAgent could not be reached'), error.name
      end
    end
  end

  describe '#web_url' do
    it 'is the company’s own site, from its subdomain, read once' do
      connect!
      answer ok({ 'company' => { 'subdomain' => 'acme', 'name' => 'Acme Ltd' } })

      expect(client.web_url).to eq('https://acme.freeagent.com')
      client.web_url
      expect(api_calls.map { call(it) }).to eq([['GET', '/v2/company']])
    end
  end

  describe 'writing expenses' do
    let(:url) { 'https://api.freeagent.com/v2/expenses/77' }
    let(:attributes) { { user: 'https://api.freeagent.com/v2/users/1', description: 'Lunch', gross_value: '-24.00' } }

    it 'creates one, wrapped as FreeAgent takes it, and answers with its url' do
      connect!
      answer response(Net::HTTPCreated, '201', JSON.generate({ 'expense' => {} }), Location: url)

      expect(client.create_expense(attributes)).to eq(url)
      request = api_calls.last
      expect(call(request)).to eq(['POST', '/v2/expenses'])
      expect(request['Content-Type']).to eq('application/json')
      expect(JSON.parse(request.body)).to eq('expense' => attributes.transform_keys(&:to_s))
    end

    it 'says why FreeAgent refused one' do
      connect!
      refused = JSON.generate({ 'errors' => { 'error' => { 'message' => 'Category is not valid' } } })
      answer response(Net::HTTPUnprocessableEntity, '422', refused)

      expect { client.create_expense(attributes) }
        .to raise_error(FreeAgent::Error, 'FreeAgent refused it: Category is not valid')
    end

    # A create that didn't answer may have been done: it's never tried again.
    it 'says FreeAgent couldn’t be reached, distinctly, asking once' do
      connect!
      allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout)

      expect { client.create_expense(attributes) }.to raise_error(FreeAgent::Unreachable)
      expect(Net::HTTP).to have_received(:start).once
    end

    it 'updates and deletes one at its url, a gone one counting as deleted' do
      connect!
      answer ok({})
      client.update_expense(url, attributes)
      expect(call(api_calls.last)).to eq(['PUT', '/v2/expenses/77'])
      expect(JSON.parse(api_calls.last.body)).to eq('expense' => attributes.transform_keys(&:to_s))

      client.delete_expense(url)
      expect(call(api_calls.last)).to eq(['DELETE', '/v2/expenses/77'])

      answer response(Net::HTTPNotFound, '404')
      expect { client.delete_expense(url) }.not_to raise_error
    end

    it 'reads who it claims them for once: the connected person' do
      connect!
      answer ok({ 'user' => { 'url' => 'https://api.freeagent.com/v2/users/1', 'role' => 'Director' } })

      2.times { expect(client.current_user_url).to eq('https://api.freeagent.com/v2/users/1') }
      expect(api_calls.map { call(it) }).to eq([['GET', '/v2/users/me']])
    end

    it 'forgets who it was, and the company, once disconnected' do
      connect!
      answer ok({ 'user' => { 'url' => 'https://api.freeagent.com/v2/users/1' } })
      client.current_user_url
      client.disconnect
      connect!
      answer ok({ 'user' => { 'url' => 'https://api.freeagent.com/v2/users/2' } })

      expect(client.current_user_url).to eq('https://api.freeagent.com/v2/users/2')
    end
  end

  describe '#categories' do
    def category(code, name)
      { 'url' => "https://api.freeagent.com/v2/categories/#{code}", 'nominal_code' => code, 'description' => name }
    end

    it 'reads every group of categories, by url, once' do
      connect!
      answer(ok({
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
      expect(api_calls.map { call(it) }).to eq([['GET', '/v2/categories']])
    end
  end
end
