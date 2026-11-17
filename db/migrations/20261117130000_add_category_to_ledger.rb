# frozen_string_literal: true

# Expenses::Ledger: each filed expense's category, for totals by category.
# Rows already there get theirs once the group is reset
# (`bin/sid sourced groups reset expenses.ledger`), which rebuilds them.
Sequel.migration do
  change do
    alter_table(:ledger) do
      add_column :category, String
      add_index :category
    end
  end
end
