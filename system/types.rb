# frozen_string_literal: true

# The app's types: Sourced's (and through them Plumb's), so message
# attributes read String, Types::UUID::V4, Types::AutoUUID and the
# rest. App-wide types can be added here too.
module Types
  include Sourced::Types
end
