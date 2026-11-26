# frozen_string_literal: true

# OAuth tokens for the systems expenses are imported from (Integrations::FreeAgent::Tokens):
# one row per provider. Kept here, never in the event store: commands and
# events are shown in the history feed and the Sourced dashboard.
Sequel.migration do
  change do
    create_table(:oauth_tokens) do
      String :provider, primary_key: true
      String :access_token, text: true, null: false
      String :refresh_token, text: true, null: false
      Time :expires_at, null: false # the access token's
      Time :updated_at, null: false
    end
  end
end
