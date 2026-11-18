# frozen_string_literal: true

# The real Expenses::LLM, not the specs' fake: what it's configured with
# and what it says when it can't ask. Nothing here reaches a provider.
RSpec.describe Expenses::LLM do
  # ENV as +vars+ say (nil unsets one) for the block, as it was after.
  def with_env(vars)
    before = vars.keys.to_h { [it, ENV.fetch(it, nil)] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
    yield
  ensure
    before.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  end

  def llm(**options) = described_class.new(model: 'gpt-4.1', judgment_model: 'gpt-6-luna', **options)

  it 'asks OpenAI by default' do
    expect(llm).to have_attributes(provider: 'openai', judgment_provider: 'openai')
  end

  it 'takes any provider RubyLLM knows, for each of its models' do
    expect(llm(provider: :anthropic, judgment_provider: 'openrouter'))
      .to have_attributes(provider: 'anthropic', judgment_provider: 'openrouter')
  end

  it 'refuses a provider RubyLLM does not know, when it is built' do
    expect { llm(provider: 'clippy') }.to raise_error(ArgumentError, /no provider "clippy": one of .*anthropic/)
  end

  it "names the provider's missing setting, on the first question to it" do
    with_env('ANTHROPIC_API_KEY' => nil) do
      expect { llm(provider: 'anthropic').ask(instructions: 'x', schema: {}, message: 'x') }
        .to raise_error(described_class::Error, 'ANTHROPIC_API_KEY is not set, for anthropic')
    end
  end

  it 'reads only the settings of the provider asked' do
    with_env('OPENAI_API_KEY' => nil, 'ANTHROPIC_API_KEY' => 'sk-ant-test') do
      config = llm(provider: 'anthropic').send(:context, 'anthropic').config

      expect(config.anthropic_api_key).to eq('sk-ant-test')
      expect { llm.send(:context, 'openai') }.to raise_error(described_class::Error, /OPENAI_API_KEY is not set/)
    end
  end

  it 'says so for a judgment provider that answers no judgments' do
    with_env('ANTHROPIC_API_KEY' => 'sk-ant-test') do
      expect { llm(judgment_provider: 'anthropic', judgment_model: 'claude-sonnet-4-5').categorize(description: 'Uber') }
        .to raise_error(described_class::Error, "Anthropic doesn't answer judgments: choose another LLM_JUDGMENT_PROVIDER")
    end
  end
end
