# frozen_string_literal: true

# Expenses::DocumentList: one row per uploaded document, for the home page's
# documents being read and those that couldn't be.
#
# Expenses::ExpenseList: one row per expense, however it was drafted, for
# the expense lists. Its category and VAT treatment, each the suggestion
# (the model's, the rule's) or a person's choice, and the filing country the
# VAT treatment is suggested against; the systems it's uploaded to. And its full-text index: description,
# vendor and category in one body, in an FTS5 table with the trigram
# tokenizer, so any part of a word matches, whatever its case or accents.
Sequel.migration do
  up do
    create_table(:documents) do
      String :document_id, primary_key: true
      String :filename, null: false
      String :content_type
      String :file_ref
      String :machine, text: true, null: false, default: '[]' # the machine's paths, JSON
      String :failure, text: true                             # why the scan failed
      String :rejection, text: true                           # why it isn't a receipt
      String :description
      String :vendor
      Integer :total_cents
      String :currency
      Date :incurred_on
      Time :uploaded_at, null: false
      Time :updated_at, null: false

      index :uploaded_at
    end

    create_table(:expenses) do
      String :expense_id, primary_key: true
      String :document_id                                     # the document attached, if any
      String :source                                          # the system it was imported from, if any
      String :uploaded_to, text: true, null: false, default: '[]' # the systems it's uploaded to, JSON
      String :upload_failed_to, text: true, null: false, default: '[]' # those its last upload or deletion failed for, JSON
      String :machine, text: true, null: false, default: '[]' # the machine's paths, JSON
      String :description
      String :vendor
      Integer :total_cents
      String :currency
      Date :incurred_on
      String :category
      TrueClass :category_chosen, null: false, default: false
      String :filing_country
      String :vat_treatment
      TrueClass :vat_confirmed, null: false, default: false
      Time :created_at, null: false
      Time :updated_at, null: false

      index :created_at
    end

    run <<~SQL
      CREATE VIRTUAL TABLE expenses_search
      USING fts5(expense_id UNINDEXED, body, tokenize = 'trigram remove_diacritics 1')
    SQL
  end

  down do
    drop_table(:expenses_search)
    drop_table(:expenses)
    drop_table(:documents)
  end
end
