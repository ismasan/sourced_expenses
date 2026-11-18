# frozen_string_literal: true

require 'ruby_llm'

# The models that read uploads and suggest their categories
# (Expenses::LLM), each from any provider RubyLLM supports. The scanner and
# categorizer get it with `dep :llm`; specs replace it with a fake.
#
#   LLM_PROVIDER / LLM_MODEL                      the scan steps: openai and gpt-4.1 by default
#   LLM_JUDGMENT_PROVIDER / LLM_JUDGMENT_MODEL    the categories: openai and gpt-6-luna by default
#
#   LLM_PROVIDER=anthropic LLM_MODEL=claude-sonnet-4-5 bin/dev
#
# The defaults are OpenAI's models, so another provider needs its model
# named: otherwise its first question fails, RubyLLM not knowing the model
# for it. A provider RubyLLM doesn't have fails the build.
#
# A provider's credentials come from the environment (or .env, see
# boot.rb), named after its RubyLLM settings: OPENAI_API_KEY,
# ANTHROPIC_API_KEY, GEMINI_API_KEY, OLLAMA_API_BASE, BEDROCK_REGION and so on.
#
# The scan model must read PDFs and images and answer to a JSON schema.
# Categories are a RubyLLM judgment (Expenses::CategoryJudge), which only
# some providers answer: openai, azure, ollama, ollama_cloud, openrouter
# and typesafe in RubyLLM 2.2 (not anthropic or gemini).
#
# gpt-4.1 by default: gpt-4.1-mini, as fast, read a text-free icon as a
# receipt with high confidence, so it never reached the verification step.
Sidereal.config.tap do |c|
  provider = Sidereal::Types::String.options(RubyLLM::Provider.providers.keys.map(&:to_s))

  c.declare('llm.provider', provider.default('openai'))
  c.declare('llm.model', Sidereal::Types::String.default('gpt-4.1'))
  c.declare('llm.judgment_provider', provider.default('openai'))
  c.declare('llm.judgment_model', Sidereal::Types::String.default('gpt-6-luna'))
  c.env(
    'LLM_PROVIDER' => 'llm.provider',
    'LLM_MODEL' => 'llm.model',
    'LLM_JUDGMENT_PROVIDER' => 'llm.judgment_provider',
    'LLM_JUDGMENT_MODEL' => 'llm.judgment_model'
  )

  c.declare('llm', Sidereal::Types::Interface[:ask, :categorize])
  c.config!('llm', ['llm.provider', 'llm.model', 'llm.judgment_provider', 'llm.judgment_model']) do |provider, model, judgment_provider, judgment_model|
    Expenses::LLM.new(provider:, model:, judgment_provider:, judgment_model:)
  end
end
