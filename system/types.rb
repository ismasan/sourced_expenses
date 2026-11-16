# frozen_string_literal: true

# The app's types: Sourced's (and through them Plumb's), so message
# attributes read String, Types::UUID::V4, Types::AutoUUID and the
# rest. App-wide types can be added here too.
module Types
  include Sourced::Types

  # A Date from its ISO 8601 string (YYYY-MM-DD), as the prompts ask the
  # model for and the exchange rate service sends: Plumb's form codec. A
  # blank string or nil is nil; anything else fails to resolve.
  ISODate = Plumb::Codec::Forms >> Date.nullable

  # +value+ as a Date, or nil if it isn't an ISO 8601 date.
  def self.iso_date(value)
    result = ISODate.resolve(value)
    result.valid? ? result.value : nil
  end
end
