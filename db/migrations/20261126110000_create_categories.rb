# frozen_string_literal: true

# Expenses::CategoryList: every category an expense has had, by key, with
# the name it came with (a source's, for one of its own) and where from.
Sequel.migration do
  change do
    create_table(:categories) do
      String :key, primary_key: true
      String :label    # nil for the baseline's: Expenses::CATEGORIES names them
      String :source   # the system it came from, if any (freeagent)
      Time :first_seen_at, null: false
    end
  end
end
