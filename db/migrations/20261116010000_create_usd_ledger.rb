# frozen_string_literal: true

# Expenses::USDLedger: one row per filed expense, with its total in US
# dollars once converted, for totals by month. Voided expenses leave it.
Sequel.migration do
  change do
    create_table(:usd_ledger) do
      String :expense_id, primary_key: true
      String :description
      Date :incurred_on, null: false
      String :currency, null: false
      Integer :amount_cents, null: false # the filed total, VAT included, in +currency+
      Integer :usd_cents                 # nil until converted
      Time :updated_at, null: false

      index :incurred_on
    end
  end
end
