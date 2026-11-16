# frozen_string_literal: true

require 'json'
require 'net/http'

module ExchangeRates
  # Rates from the Frankfurter API (https://frankfurter.dev): the European
  # Central Bank's reference rates, one a working day, from 1999 on. Free,
  # with no key. About thirty currencies: a rarer one has no rate.
  class Frankfurter
    DEFAULT_URL = 'https://api.frankfurter.dev/v1'

    def initialize(base_url: DEFAULT_URL, timeout: 10)
      @base_url = base_url.chomp('/')
      @timeout = timeout
    end

    # The rate on +on+, or the last one before it. A date with no rate yet
    # (today's before it's published, or a date in the future) takes the
    # latest.
    #
    # @return [Rate]
    # @raise [Error]
    def rate(from:, to:, on:)
      fetch("#{on.iso8601}?base=#{from}&symbols=#{to}", from:, to:) ||
        fetch("latest?base=#{from}&symbols=#{to}", from:, to:) ||
        raise(Error, "No exchange rate from #{from} to #{to}")
    end

    private

    # The Rate at +path+, or nil when there's none there (a 404: a currency
    # it doesn't know, or a date it has no rate for).
    def fetch(path, from:, to:)
      uri = URI("#{@base_url}/#{path}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.get(uri.request_uri, 'Accept' => 'application/json')
      end
      return if response.is_a?(Net::HTTPNotFound)
      raise Error, "The exchange rate service answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      rate = body.dig('rates', to) or raise Error, "No exchange rate from #{from} to #{to}"
      date = Types.iso_date(body['date']) or raise Error, 'The exchange rate service sent an answer it could not read'
      Rate.new(rate:, date:)
    rescue JSON::ParserError
      raise Error, 'The exchange rate service sent an answer it could not read'
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError
      raise Error, 'The exchange rate service could not be reached'
    end
  end
end
