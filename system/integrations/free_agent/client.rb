# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Integrations
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

      def disconnect = @tokens.clear

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
        @web_url ||= begin
          subdomain = parse(get('/company')).dig('company', 'subdomain') or raise Error, 'FreeAgent sent no company subdomain'
          "https://#{subdomain}.#{sandbox? ? 'sandbox.' : ''}freeagent.com"
        end
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

      def get(path, query = {}, retried: false)
        token = access_token
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(query) if query.any?
        response = http(uri) do |http|
          http.get(uri.request_uri, 'Authorization' => "Bearer #{token.access_token}", 'Accept' => 'application/json',
                                    'User-Agent' => USER_AGENT)
        end
        # Refused: the token may have been revoked or rotated under us. Once.
        if response.is_a?(Net::HTTPUnauthorized) && !retried
          refresh(token)
          return get(path, query, retried: true)
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
        raise Error, 'FreeAgent could not be reached'
      end

      def check(response)
        case response
        when Net::HTTPSuccess then response
        when Net::HTTPTooManyRequests
          raise Error, "FreeAgent is rate limiting requests: try again in #{response['Retry-After'] || 60} seconds"
        when Net::HTTPUnauthorized then raise Error, 'FreeAgent refused the access token: connect it again'
        else raise Error, "FreeAgent answered #{response.code}"
        end
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
end
