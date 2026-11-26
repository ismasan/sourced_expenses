# frozen_string_literal: true

# The app's types: Sourced's (and through them Plumb's), so message
# attributes read String, Types::ExpenseID, Types::Boolean and the
# rest. App-wide types can be added here too.
# Types::String.desc("…"): a description, for the JSON Schemas made from
# Plumb types (Documents::Prompts).
Plumb.policy :desc, helper: true do |type, description|
  type.metadata(description:)
end

module Types
  include Sourced::Types

  # A Date from its ISO 8601 string (YYYY-MM-DD), as the prompts ask the
  # model for and the exchange rate service sends: Plumb's form codec. A
  # blank string or nil is nil; anything else fails to resolve.
  ISODate = Plumb::Codec::Forms >> Date.nullable

  # An uploaded document's id: the MD5 digest of its bytes, as the file
  # store keys it (32 lowercase hex characters). The same file is the same
  # document, so uploading it again changes nothing.
  DocumentID = String[/\A[0-9a-f]{32}\z/]

  # An expense's id, whatever made it: letters, digits, _ and -, up to 64,
  # so it's safe in a URL and a channel name. Its source picks it, and the
  # same id is the same expense, so making it again changes nothing: one
  # drafted from a document has the document's id, one entered by hand the
  # UUID its form was rendered with.
  ExpenseID = String[/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/]

  # +value+ as a Time, or nil if it isn't an ISO 8601 time.
  def self.iso_time(value)
    value.nil? ? nil : ::Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # +value+ as a Date, or nil if it isn't an ISO 8601 date.
  def self.iso_date(value)
    result = ISODate.resolve(value)
    result.valid? ? result.value : nil
  end
end
