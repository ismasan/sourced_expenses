# frozen_string_literal: true

# The model that reads uploads (Expenses::LLM). OpenAI, with OPENAI_API_KEY
# from the environment (or .env, see boot.rb). The scanner gets it with
# `dep :llm`; specs replace it with a fake.
#
#   OPENAI_MODEL=gpt-5-mini bin/dev
#
# gpt-4.1 by default: gpt-4.1-mini, as fast, read a text-free icon as a
# receipt with high confidence, so it never reached the verification step.
Sidereal.config.tap do |c|
  c.declare('llm.model', Sidereal::Types::String) { ENV.fetch('OPENAI_MODEL', 'gpt-4.1') }
  c.declare('llm', Sidereal::Types::Interface[:ask])
  c.config!('llm', ['llm.model']) { |model| Expenses::LLM.new(model:) }
end
