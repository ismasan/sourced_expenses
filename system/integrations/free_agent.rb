# frozen_string_literal: true

module Integrations
  # FreeAgent's API (https://dev.freeagent.com), to import expenses from:
  # the client (Client) and the tokens it connects with (Tokens), and how its
  # expenses become ours (ExpenseMapping). Integrations::FreeAgentImport runs the
  # imports.
  module FreeAgent
    # Something FreeAgent couldn't do, put for a person to read: not connected,
    # the tokens refused, rate limited, unreachable.
    Error = Class.new(StandardError)

    # FreeAgent couldn't be reached, or didn't answer in time: what was asked
    # may or may not have been done there.
    Unreachable = Class.new(Error)
  end
end
