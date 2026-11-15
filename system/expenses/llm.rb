# frozen_string_literal: true

require 'json'
require 'ruby_llm'

module Expenses
  # The model the scan steps call: one question, in a chat of its own, with
  # its own instructions and JSON schema, about one file or none. Built by
  # the `llm` component (config/components/llm.rb), and faked in specs.
  #
  #   llm.ask(instructions:, schema:, message:, file: '/path/to/data.jpg') # => Hash
  #
  # The API key is read from ENV on the first question, not at boot, so a
  # missing key fails that scan step instead of the app.
  class LLM
    Error = Class.new(StandardError)

    attr_reader :model

    def initialize(model:, timeout: 120)
      @model = model
      @timeout = timeout
    end

    # @return [Hash] the answer, symbol keys
    # @raise [LLM::Error] with a message safe to store and show: never the
    #   provider's own error text, which can echo the API key
    def ask(instructions:, schema:, message:, file: nil)
      chat = context.chat(model:).with_instructions(instructions).with_schema(schema)
      content = chat.ask(message, with: file).content
      answer = content.is_a?(String) ? JSON.parse(content) : content
      raise Error, 'The model gave an answer that is not JSON' unless answer.is_a?(Hash)

      answer.transform_keys(&:to_sym)
    rescue JSON::ParserError
      raise Error, 'The model gave an answer that is not JSON'
    rescue RubyLLM::UnauthorizedError
      raise Error, 'The OpenAI API key was refused'
    rescue RubyLLM::RateLimitError
      raise Error, 'OpenAI is rate limiting requests'
    rescue RubyLLM::ModelNotFoundError
      raise Error, "RubyLLM doesn't know the model #{model}"
    rescue RubyLLM::UnsupportedAttachmentError
      raise Error, "#{model} can't read this kind of file"
    rescue RubyLLM::Error => e
      raise Error, "The model request failed (#{e.class.name.split('::').last})"
    rescue Faraday::TimeoutError
      raise Error, "The model took longer than #{@timeout}s to answer"
    rescue Faraday::Error => e
      raise Error, "Couldn't reach the model (#{e.class.name.split('::').last})"
    end

    private

    def context
      @context ||= RubyLLM.context do |config|
        config.openai_api_key = ENV.fetch('OPENAI_API_KEY') { raise Error, 'OPENAI_API_KEY is not set' }
        config.request_timeout = @timeout
        config.max_retries = 2
        config.log_level = Logger::WARN
      end
    end
  end
end
