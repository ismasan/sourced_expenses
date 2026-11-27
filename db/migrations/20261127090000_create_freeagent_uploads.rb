# frozen_string_literal: true

# FreeAgent::UploadList: each expense this app created on
# FreeAgent, by its id there, so importing never brings one back as an
# expense of its own.
Sequel.migration do
  change do
    create_table(:freeagent_uploads) do
      String :external_id, primary_key: true # its id on FreeAgent
      String :expense_id, null: false        # the expense here it is
      Time :uploaded_at, null: false
    end
  end
end
