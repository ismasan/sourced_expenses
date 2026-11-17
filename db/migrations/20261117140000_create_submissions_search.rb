# frozen_string_literal: true

# Expenses::Submissions' full-text index: one row per submission, its
# description, vendor, filename and category in one body, in an FTS5 table
# with the trigram tokenizer, so any part of a word matches, whatever its
# case or accents. And the vendor the scan read, on the row, to index.
#
# Added, not edited into the table's own migration, so a store with
# expenses already in it keeps them: resetting expenses.submissions fills
# the index for those.
Sequel.migration do
  up do
    alter_table(:submissions) { add_column :vendor, String }
    run <<~SQL
      CREATE VIRTUAL TABLE submissions_search
      USING fts5(expense_id UNINDEXED, body, tokenize = 'trigram remove_diacritics 1')
    SQL
  end

  down do
    drop_table(:submissions_search)
    alter_table(:submissions) { drop_column :vendor }
  end
end
