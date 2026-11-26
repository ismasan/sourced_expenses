# frozen_string_literal: true

# FreeAgent (Integrations::FreeAgent::Client), to import expenses from. Its
# app's OAuth identifier and secret, from the FreeAgent Developer Dashboard
# (https://dev.freeagent.com):
#
#   FREEAGENT_CLIENT_ID       the app's OAuth identifier
#   FREEAGENT_CLIENT_SECRET   its OAuth secret
#   FREEAGENT_SANDBOX=1       its sandbox (api.sandbox.freeagent.com), not your real account:
#                             1 or true, 0 or false; unset is the real one
#   FREEAGENT_REDIRECT_URI    where FreeAgent sends you back to once connected, as the app has it
#                             in the dashboard; http://<this app's host>/integrations/freeagent/callback
#                             when unset
#
# Each is declared with its type, then implemented from ENV (`c.env`), whose
# values are decoded into those types with Plumb's forms codec: a blank or
# unset variable is nil, and one that doesn't decode (FREEAGENT_SANDBOX=yes)
# fails the build, naming the variable but not its value.
#
# Without the identifier and secret the app still boots: the FreeAgent page
# says how to set it up. The tokens a person connects with are kept in the
# database (Integrations::FreeAgent::Tokens). Integrations::FreeAgentImport
# gets the client with `dep :freeagent`; specs replace it with a fake.
Sidereal.config.tap do |c|
  c.declare('freeagent.client_id', Sidereal::Types::String.nullable,
            description: "The FreeAgent app's OAuth identifier, from its Developer Dashboard (FREEAGENT_CLIENT_ID)")
  c.declare('freeagent.client_secret', Sidereal::Types::String.nullable,
            description: "The FreeAgent app's OAuth secret (FREEAGENT_CLIENT_SECRET)")
  c.declare('freeagent.sandbox', Sidereal::Types::Boolean.nullable,
            description: "Whether to use FreeAgent's sandbox, not the real account (FREEAGENT_SANDBOX)")
  c.declare('freeagent.redirect_uri', Sidereal::Types::String.nullable,
            description: "Where FreeAgent sends a person back to once connected, as the app has it in the dashboard: this app's callback when unset (FREEAGENT_REDIRECT_URI)")
  c.declare('freeagent.tokens', Sidereal::Types::Interface[:load, :save, :clear],
            description: 'The OAuth tokens a person connected FreeAgent with, kept in the database')
  c.declare('freeagent', Sidereal::Types::Interface[:expenses, :categories, :web_url, :configured?, :connected?, :disconnect,
                                                          :current_user_url, :company_currency, :create_expense,
                                                          :update_expense, :delete_expense],
            description: "FreeAgent's API client, to import expenses and upload them")

  c.env(
    'FREEAGENT_CLIENT_ID' => 'freeagent.client_id',
    'FREEAGENT_CLIENT_SECRET' => 'freeagent.client_secret',
    'FREEAGENT_SANDBOX' => 'freeagent.sandbox',
    'FREEAGENT_REDIRECT_URI' => 'freeagent.redirect_uri'
  )

  c.config!('freeagent.tokens', ['db']) { |db| Integrations::FreeAgent::Tokens.new(db:) }
  c.config!('freeagent', ['freeagent.client_id', 'freeagent.client_secret', 'freeagent.sandbox', 'freeagent.tokens']) do |client_id, client_secret, sandbox, tokens|
    Integrations::FreeAgent::Client.new(client_id:, client_secret:, sandbox: sandbox == true, tokens:)
  end
end
