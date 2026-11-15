# frozen_string_literal: true

# Expenses::Submissions: one row per uploaded document, for the list on the
# home page. The projector rewrites a row whenever its expense moves.
Sequel.migration do
  change do
    create_table(:submissions) do
      String :expense_id, primary_key: true
      String :filename, null: false
      String :content_type
      String :file_ref
      String :machine, text: true, null: false, default: '[]' # the machine's paths, JSON
      String :failure, text: true                             # why the scan failed
      String :rejection, text: true                           # why it isn't a receipt
      String :description
      Integer :total_cents
      String :currency
      Date :incurred_on
      Time :uploaded_at, null: false
      Time :updated_at, null: false

      index :uploaded_at
    end
  end
end
