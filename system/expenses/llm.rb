# frozen_string_literal: true

require 'json'
require 'ruby_llm'

module Expenses
  # The model the scan steps and the categorizer call. Built by the `llm`
  # component (config/components/llm.rb), and faked in specs.
  #
  # A scan step asks one question, in a chat of its own, with its own
  # instructions and JSON schema, about one file or none:
  #
  #   llm.ask(instructions:, schema:, message:, file: '/path/to/data.jpg') # => Hash
  #
  # The categorizer asks CategoryJudge which category an expense goes
  # under, of +judgment_model+ (a model OpenAI answers judgments with):
  #
  #   llm.categorize(description: 'Uber - Trip', vendor: 'Uber') # => { category: 'travel', probability: 0.93 }
  #
  # The API key is read from ENV on the first question, not at boot, so a
  # missing key fails that step instead of the app.
  class LLM
    Error = Class.new(StandardError)

    attr_reader :model, :judgment_model

    def initialize(model:, judgment_model:, timeout: 120)
      @model = model
      @judgment_model = judgment_model
      @timeout = timeout
    end

    # @return [Hash] the answer, symbol keys
    # @raise [LLM::Error] with a message safe to store and show: never the
    #   provider's own error text, which can echo the API key
    def ask(instructions:, schema:, message:, file: nil)
      answer = rescuing(model) do
        chat = context.chat(model:).with_instructions(instructions).with_schema(schema)
        content = chat.ask(message, with: file).content
        content.is_a?(String) ? JSON.parse(content) : content
      end
      raise Error, 'The model gave an answer that is not JSON' unless answer.is_a?(Hash)

      answer.transform_keys(&:to_sym)
    end

    # +expense+, what's known about it (description, vendor and the like:
    # nils are left out), judged against CATEGORIES.
    # @return [Hash] +category+ (a CATEGORIES key) and its +probability+
    # @raise [LLM::Error] as #ask
    def categorize(**expense)
      answer = rescuing(judgment_model) do
        CategoryJudge.judge(expense.compact, context:, model: judgment_model, provider: :openai).category
      end
      { category: answer.choice, probability: answer.probabilities.fetch(answer.choice).to_f.round(4) }
    end

    private

    def rescuing(model)
      yield
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
