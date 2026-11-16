# frozen_string_literal: true

# Expenses::Ledger: one row per filed expense, with its total converted to
# the reporting currency once recorded (and which currency that is), for
# totals by month. Voided expenses leave it.
Sequel.migration do
  change do
    create_table(:ledger) do
      String :expense_id, primary_key: true
      String :description
      Date :incurred_on, null: false
      String :currency, null: false
      Integer :amount_cents, null: false # the filed total, VAT included, in +currency+
      String :reporting_currency         # what it was converted to, nil until converted
      Integer :reporting_cents           # in +reporting_currency+
      Time :updated_at, null: false

      index :incurred_on
    end
  end
end
