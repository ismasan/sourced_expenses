# frozen_string_literal: true

# How many expenses scan at once (Expense's scan queue, a WorkQueue), 3 unless
# MAX_SCANS says otherwise. Each scan makes up to four model calls, one
# after another, so this caps the model calls in flight for scanning.
#
#   MAX_SCANS=5 bin/dev
Sidereal.config.tap do |c|
  c.declare('expenses.max_scans', Sidereal::Types::Integer[1..]) { Integer(ENV.fetch('MAX_SCANS', '3')) }
end
