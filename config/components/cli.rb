# frozen_string_literal: true

# The app's own `bin/sid` commands (cli/), such as `bin/sid expenses upload`.
# Only when `sid` is running: Sidereal::CLI isn't loaded in the web app.
if defined?(Sidereal::CLI)
  require_relative '../../cli/expenses'
  Sidereal::CLI.register 'expenses', CLI::Expenses
end
