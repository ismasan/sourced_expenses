# frozen_string_literal: true

module Documents
  RSpec.describe Prompts do
    SCHEMAS = %i[EXTRACTION_SCHEMA DOCUMENT_VERIFICATION_SCHEMA DATE_RECHECK_SCHEMA CLEANUP_SCHEMA].freeze

    # Every object in +schema+, nested ones included.
    def objects(schema)
      return schema.flat_map { objects(it) } if schema.is_a?(Array)
      return [] unless schema.is_a?(Hash)

      own = schema[:type] == 'object' ? [schema] : []
      own + schema.values.flat_map { objects(it) }
    end

    SCHEMAS.each do |name|
      it "makes #{name} one OpenAI's strict mode takes: closed objects, every key required" do
        objects(Prompts.const_get(name)).each do |object|
          expect(object).to include(additionalProperties: false, required: object[:properties].keys.map(&:to_s))
        end
      end
    end

    it 'writes a nullable field as a type with null, an enum as an enum' do
      properties = Prompts::EXTRACTION_SCHEMA[:properties]

      expect(properties[:net_amount]).to match(type: %w[number null], description: include('net amount'))
      expect(properties[:confidence]).to match(type: 'string', enum: %w[high medium low], description: include('confidence'))
    end
  end
end
