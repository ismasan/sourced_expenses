# frozen_string_literal: true

# FreeAgent (https://dev.freeagent.com): importing its expenses, and
# uploading ours to it. Its reactors are here, in consumer groups of their
# own (freeagent.*):
#
#   Import      imports an account's expenses, a run at a time
#   Settings    whether expenses filed here are uploaded
#   Upload      uploads an expense, corrects it, deletes it there
#   UploadList  the expenses uploaded, so Import leaves them alone
#
# and their helpers in lib/: the API client (Client), the tokens it
# connects with (Tokens), and how an expense goes between theirs and ours
# (ExpenseMapping, UploadMapping).
module FreeAgent
  # Something FreeAgent couldn't do, put for a person to read: not connected,
  # the tokens refused, rate limited, unreachable.
  Error = Class.new(StandardError)

  # FreeAgent couldn't be reached, or didn't answer in time: what was asked
  # may or may not have been done there.
  Unreachable = Class.new(Error)
end
