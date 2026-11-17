# frozen_string_literal: true

# Expenses::Submissions: each expense's category, the model's suggestion
# or a person's choice. Added, not edited into the table's own migration,
# so a store with expenses already in it keeps them: the categorizer
# catches up on those once the app starts.
Sequel.migration do
  change do
    alter_table(:submissions) do
      add_column :category, String
      add_column :category_chosen, TrueClass, null: false, default: false
    end
  end
end
