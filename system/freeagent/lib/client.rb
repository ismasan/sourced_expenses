# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module FreeAgent
  # FreeAgent's API (https://dev.freeagent.com/docs), as this app uses it:
  # connecting (OAuth 2: the authorization code, then refresh tokens, kept in
  # Tokens) and reading expenses and categories. Its production API, or the
  # sandbox's (https://api.sandbox.freeagent.com) with +sandbox: true+.
  #
  #   client.authorize_url(redirect_uri:, state:)   # send the browser here
  #   client.connect(code:, redirect_uri:)          # with what it comes back with
  #   client.expenses(updated_since: time, page: 1) # => Page
  #   client.categories                             # => { url => Category }
  #   client.web_url                                # => "https://<company>.freeagent.com"
  #
  # The access token is refreshed when it's about to expire, and once more
  # if FreeAgent refuses it.
  class Client
    PRODUCTION = 'https://api.freeagent.com/v2'
    SANDBOX = 'https://api.sandbox.freeagent.com/v2'

    # FreeAgent asks every app to name itself: a generic name, nothing about
    # whose books these are.
    USER_AGENT = 'sourced-expenses'

    # Expenses per page: FreeAgent's most.
    PER_PAGE = 100

    # Categories change rarely: read again after this long.
    CATEGORIES_TTL = 3600

    # One page of expenses (FreeAgent's JSON objects), and the next page's
    # number, nil on the last.
    Page = ::Data.define(:expenses, :next_page)

    Category = ::Data.define(:url, :nominal_code, :description)

    def initialize(client_id:, client_secret:, tokens:, sandbox: false, timeout: 20)
      @client_id = client_id
      @client_secret = client_secret
      @tokens = tokens
      @base_url = sandbox ? SANDBOX : PRODUCTION
      @timeout = timeout
      @categories = nil
    end

    # Whether the app has its OAuth identifier and secret.
    def configured? = !blank?(@client_id) && !blank?(@client_secret)

    # Whether a person has connected their account.
    def connected? = !@tokens.load.nil?

    def sandbox? = @base_url == SANDBOX

    # Where to send a person to let this app read their account. FreeAgent
    # sends them back to +redirect_uri+ (it must be one the app has in the
    # Developer Dashboard) with +state+ and a code for #connect.
    def authorize_url(redirect_uri:, state:)
      query = URI.encode_www_form(client_id: @client_id, response_type: 'code', redirect_uri:, state:)
      "#{@base_url}/approve_app?#{query}"
    end

    # Trades the code FreeAgent sent back for tokens, and keeps them.
    # @raise [Error]
    def connect(code:, redirect_uri:)
      @tokens.save(token_request(grant_type: 'authorization_code', code:, redirect_uri:))
    end

    # Forgets the tokens, and what was read with them: another account may
    # be connected next.
    def disconnect
      @tokens.clear
      @company = @current_user_url = @categories = nil
    end

    # Expenses updated since +updated_since+ (any, for nil), a page at a
    # time.
    # @return [Page]
    # @raise [Error]
    def expenses(updated_since: nil, page: 1)
      query = { page:, per_page: PER_PAGE }
      query[:updated_since] = updated_since.utc.iso8601 if updated_since
      response = get('/expenses', query)
      Page.new(expenses: parse(response).fetch('expenses', []), next_page: next_page(response))
    end

    # The company's own FreeAgent site, where a person sees its expenses:
    # https://<its subdomain>.freeagent.com (.sandbox.freeagent.com on the
    # sandbox). Read once.
    # @return [String]
    # @raise [Error]
    def web_url
      subdomain = company['subdomain'] or raise Error, 'FreeAgent sent no company subdomain'
      "https://#{subdomain}.#{sandbox? ? 'sandbox.' : ''}freeagent.com"
    end

    # The company's own currency (its +currency+), or nil if FreeAgent sends
    # none.
    # @return [String, nil]
    # @raise [Error]
    def company_currency = company['currency']

    # The company FreeAgent answers for: read once.
    # @return [Hash]
    # @raise [Error]
    def company
      @company ||= parse(get('/company')).fetch('company') { raise Error, 'FreeAgent sent no company' }
    end

    # The connected person's own url: who the expenses this app creates are
    # claimed by. Read once.
    # @return [String]
    # @raise [Error]
    def current_user_url
      @current_user_url ||= parse(get('/users/me')).dig('user', 'url') or raise Error, 'FreeAgent sent no user'
    end

    # Creates an expense (+attributes+: FreeAgent's), claimed by
    # +attributes[:user]+.
    # @return [String] its url, from the Location FreeAgent answers with
    # @raise [Unreachable] when it may or may not have been created
    # @raise [Error]
    def create_expense(attributes)
      response = request(Net::HTTP::Post, '/expenses', body: { expense: attributes })
      response['Location'] || parse(response).dig('expense', 'url') or raise Error, 'FreeAgent sent no url for the expense'
    end

    # Updates the expense at +url+ with +attributes+.
    # @raise [Error]
    def update_expense(url, attributes)
      request(Net::HTTP::Put, url, body: { expense: attributes })
      nil
    end

    # Deletes the expense at +url+: done already, if FreeAgent has none there.
    # @raise [Error]
    def delete_expense(url)
      request(Net::HTTP::Delete, url)
      nil
    rescue Error => e
      raise unless e.message == 'FreeAgent answered 404'
    end

    # Every category the company has, by url (an expense's +category+).
    # @return [Hash{String => Category}]
    # @raise [Error]
    def categories
      return @categories[:all] if @categories && @categories[:at] > Time.now - CATEGORIES_TTL

      body = parse(get('/categories'))
      all = body.values.grep(Array).flatten.to_h do |c|
        [c['url'], Category.new(url: c['url'], nominal_code: c['nominal_code'], description: c['description'])]
      end
      @categories = { all:, at: Time.now }
      all
    end

    private

    def get(path, query = {}) = request(Net::HTTP::Get, path, query:)

    # +method+ (a Net::HTTP request class) at +path+, with +body+ as JSON:
    # the token refreshed first if it's about to expire, and once more if
    # FreeAgent refuses it (nothing was done then, so it's safe to ask
    # again). Never retried otherwise: a create that timed out may have
    # been done.
    def request(method, path, query: {}, body: nil, retried: false)
      token = access_token
      uri = URI(path.start_with?('http') ? path : "#{@base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query.any?
      req = method.new(uri)
      req['Authorization'] = "Bearer #{token.access_token}"
      req['Accept'] = 'application/json'
      req['User-Agent'] = USER_AGENT
      if body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end
      response = http(uri) { it.request(req) }
      if response.is_a?(Net::HTTPUnauthorized) && !retried
        refresh(token)
        return request(method, path, query:, body:, retried: true)
      end

      check(response)
    end

    # A token that's good now, refreshed if it's about to expire.
    def access_token
      token = @tokens.load or raise Error, 'FreeAgent isn’t connected'
      token.expired? ? refresh(token) : token
    end

    def refresh(token)
      @tokens.save(token_request(grant_type: 'refresh_token', refresh_token: token.refresh_token))
    end

    # The token endpoint, with the app's identifier and secret as Basic auth.
    def token_request(**form)
      uri = URI("#{@base_url}/token_endpoint")
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(@client_id, @client_secret)
      request['Accept'] = 'application/json'
      request['User-Agent'] = USER_AGENT
      request.set_form_data(form)
      response = http(uri) { it.request(request) }
      raise Error, 'FreeAgent refused the connection: connect it again' if response.is_a?(Net::HTTPClientError) &&
                                                                          !response.is_a?(Net::HTTPTooManyRequests)

      parse(check(response))
    end

    def http(uri, &)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: @timeout,
                                          read_timeout: @timeout, &)
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError
      raise Unreachable, 'FreeAgent could not be reached'
    end

    def check(response)
      case response
      when Net::HTTPSuccess then response
      when Net::HTTPTooManyRequests
        raise Error, "FreeAgent is rate limiting requests: try again in #{response['Retry-After'] || 60} seconds"
      when Net::HTTPUnauthorized then raise Error, 'FreeAgent refused the access token: connect it again'
      when Net::HTTPUnprocessableEntity, Net::HTTPBadRequest
        raise Error, "FreeAgent refused it: #{refusal(response) || response.code}"
      else raise Error, "FreeAgent answered #{response.code}"
      end
    end

    # FreeAgent's reason for refusing a request, from its errors (one, or a
    # list), or nil.
    def refusal(response)
      errors = JSON.parse(response.body.to_s)['errors']
      list = case errors
             when Hash then errors.key?('error') ? [errors['error']].flatten : errors.values
             else Array(errors)
             end
      messages = list.filter_map { it.is_a?(Hash) ? it['message'] : it.to_s }
      messages.join('; ') unless messages.empty?
    rescue JSON::ParserError
      nil
    end

    def parse(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, 'FreeAgent sent an answer that could not be read'
    end

    # The next page's number, from the Link header (rel="next"), or nil.
    def next_page(response)
      link = response['Link'].to_s.split(',').find { it.include?('rel="next"') } or return
      url = link[/<([^>]+)>/, 1] or return
      Integer(URI.decode_www_form(URI(url).query.to_s).to_h['page'], exception: false)
    end

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
