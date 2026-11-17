# frozen_string_literal: true

# The model that reads uploads and suggests their categories
# (Expenses::LLM). OpenAI, with OPENAI_API_KEY from the environment (or
# .env, see boot.rb). The scanner and categorizer get it with `dep :llm`;
# specs replace it with a fake.
#
#   OPENAI_MODEL=gpt-5-mini bin/dev
#
# gpt-4.1 by default: gpt-4.1-mini, as fast, read a text-free icon as a
# receipt with high confidence, so it never reached the verification step.
#
# Categories are a RubyLLM judgment (Expenses::CategoryJudge), which needs
# a model OpenAI answers judgments with: OPENAI_JUDGMENT_MODEL, gpt-6-luna
# by default.
Sidereal.config.tap do |c|
  c.declare('llm.model', Sidereal::Types::String) { ENV.fetch('OPENAI_MODEL', 'gpt-4.1') }
  c.declare('llm.judgment_model', Sidereal::Types::String) { ENV.fetch('OPENAI_JUDGMENT_MODEL', 'gpt-6-luna') }
  c.declare('llm', Sidereal::Types::Interface[:ask, :categorize])
  c.config!('llm', ['llm.model', 'llm.judgment_model']) do |model, judgment_model|
    Expenses::LLM.new(model:, judgment_model:)
  end
end
