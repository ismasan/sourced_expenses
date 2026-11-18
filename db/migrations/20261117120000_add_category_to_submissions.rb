# frozen_string_literal: true

# Expenses::Submissions: each expense's category and VAT treatment, each
# the suggestion (the model's, the rule's) or a person's choice, and the
# filing country the VAT treatment is suggested against. Added, not edited
# into the table's own migration, so a store with expenses already in it
# keeps them: the categorizer catches up on those once the app starts.
Sequel.migration do
  change do
    alter_table(:submissions) do
      add_column :category, String
      add_column :category_chosen, TrueClass, null: false, default: false
      add_column :filing_country, String
      add_column :vat_treatment, String
      add_column :vat_confirmed, TrueClass, null: false, default: false
    end
  end
end
