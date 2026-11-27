# frozen_string_literal: true

module FreeAgent
  # The OAuth tokens FreeAgent issued this app, in the `oauth_tokens` table:
  # one access token (an hour) and one refresh token. FreeAgent may hand out
  # a new refresh token on every refresh, so each refresh's tokens replace
  # the last.
  class Tokens
    PROVIDER = 'freeagent'

    Token = ::Data.define(:access_token, :refresh_token, :expires_at) do
      # Expired, or about to: refresh it before using it.
      def expired?(now = Time.now) = expires_at <= now + 60
    end

    def initialize(db:)
      @db = db
    end

    # @return [Token, nil] nil when FreeAgent isn't connected
    def load
      row = rows.where(provider: PROVIDER).first or return
      Token.new(**row.slice(:access_token, :refresh_token, :expires_at))
    end

    # Tokens from FreeAgent's token endpoint (its JSON answer).
    # @return [Token]
    def save(answer, now: Time.now)
      token = Token.new(access_token: answer.fetch('access_token'), refresh_token: answer.fetch('refresh_token'),
                        expires_at: now + Integer(answer.fetch('expires_in', 3600)))
      row = token.to_h.merge(updated_at: now)
      rows.insert_conflict(target: :provider, update: row).insert(row.merge(provider: PROVIDER))
      token
    end

    def clear = rows.where(provider: PROVIDER).delete

    private

    def rows = @db[:oauth_tokens]
  end
end
