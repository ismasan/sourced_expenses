# frozen_string_literal: true

require 'json'
require 'ruby_llm'

module Expenses
  # The models the scan steps and the categorizer call, each of its own
  # provider (any RubyLLM supports). Built by the `llm` component
  # (config/components/llm.rb), and faked in specs.
  #
  # A scan step asks one question, in a chat of its own, with its own
  # instructions and JSON schema, about one file or none:
  #
  #   llm.ask(instructions:, schema:, message:, file: '/path/to/data.jpg') # => Hash
  #
  # The categorizer asks CategoryJudge which category an expense goes
  # under, of +judgment_model+ (a model its provider answers judgments with):
  #
  #   llm.categorize(description: 'Uber - Trip', vendor: 'Uber') # => { category: 'travel', probability: 0.93 }
  #
  # A provider's credentials are its RubyLLM settings, each read from the
  # ENV variable of the same name (anthropic_api_key from
  # ANTHROPIC_API_KEY), on the first question to it, not at boot: a
  # missing key fails that step instead of the app.
  class LLM
    Error = Class.new(StandardError)

    attr_reader :provider, :model, :judgment_provider, :judgment_model

    # @raise [ArgumentError] for a provider RubyLLM doesn't know
    def initialize(model:, judgment_model:, provider: 'openai', judgment_provider: 'openai', timeout: 120)
      @provider = known_provider(provider)
      @model = model
      @judgment_provider = known_provider(judgment_provider)
      @judgment_model = judgment_model
      @timeout = timeout
      @contexts = {}
    end

    # @return [Hash] the answer, symbol keys
    # @raise [LLM::Error] with a message safe to store and show: never the
    #   provider's own error text, which can echo the API key
    def ask(instructions:, schema:, message:, file: nil)
      answer = rescuing(provider, model) do
        chat = context(provider).chat(model:, provider:).with_instructions(instructions).with_schema(schema)
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
      answer = rescuing(judgment_provider, judgment_model) do
        CategoryJudge.judge(expense.compact, context: context(judgment_provider), model: judgment_model,
                                             provider: judgment_provider).category
      end
      { category: answer.choice, probability: answer.probabilities.fetch(answer.choice).to_f.round(4) }
    end

    private

    # RubyLLM's own refusal of a judgment it has no protocol for: its
    # message, not the provider's, so safe to show.
    NO_JUDGMENTS = /doesn't support judgments\z/

    def rescuing(provider, model)
      yield
    rescue JSON::ParserError
      raise Error, 'The model gave an answer that is not JSON'
    rescue RubyLLM::UnauthorizedError
      raise Error, "The #{provider_name(provider)} credentials were refused"
    rescue RubyLLM::RateLimitError
      raise Error, "#{provider_name(provider)} is rate limiting requests"
    rescue RubyLLM::ModelNotFoundError
      raise Error, "RubyLLM doesn't know the model #{model} for #{provider}"
    rescue RubyLLM::UnsupportedAttachmentError
      raise Error, "#{model} can't read this kind of file"
    rescue RubyLLM::Error => e
      raise Error, "#{provider_name(provider)} doesn't answer judgments: choose another LLM_JUDGMENT_PROVIDER" if
        e.message.match?(NO_JUDGMENTS)

      raise Error, "The model request failed (#{e.class.name.split('::').last})"
    rescue Faraday::TimeoutError
      raise Error, "The model took longer than #{@timeout}s to answer"
    rescue Faraday::Error => e
      raise Error, "Couldn't reach the model (#{e.class.name.split('::').last})"
    end

    def known_provider(name)
      name = name.to_s
      return name if RubyLLM::Provider.resolve(name)

      raise ArgumentError, "RubyLLM has no provider #{name.inspect}: one of #{RubyLLM::Provider.providers.keys.join(', ')}"
    end

    def provider_name(provider) = RubyLLM::Provider.resolve(provider).name.split('::').last

    # A context per provider, with only its settings: a missing key for one
    # fails only the questions to it.
    def context(provider)
      @contexts[provider] ||= RubyLLM.context do |config|
        klass = RubyLLM::Provider.resolve(provider)
        klass.configuration_options.each do |option|
          value = ENV[option.to_s.upcase]
          config.public_send(:"#{option}=", value) if value
        end
        missing = klass.configuration_requirements.map { it.to_s.upcase }.reject { ENV[it] }
        raise Error, "#{missing.join(', ')} #{missing.one? ? 'is' : 'are'} not set, for #{provider}" if missing.any?

        config.request_timeout = @timeout
        config.max_retries = 2
        config.log_level = Logger::WARN
      end
    end
  end
end
