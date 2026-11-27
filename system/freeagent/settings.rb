# frozen_string_literal: true

module FreeAgent
  # A FreeAgent account's settings, as a person sets them on its page: for
  # now, whether expenses filed here are uploaded to it
  # (Upload). Off until turned on.
  #
  #   initial, off ─TurnUploadsOn─▶ on ─TurnUploadsOff─▶ off
  #
  # Uploads only expenses filed while it's on: .uploads_on_since is when it
  # was last turned on, nil while it's off.
  class Settings < Sourced::Machine
    partition_by account: Types::String.present
    consumer_group 'freeagent.settings'
    message_prefix 'freeagent_settings'

    # The one account there is, for now: Import's.
    ACCOUNT = Import::ACCOUNT

    On = State(:on)
    Off = State(:off)

    TurnUploadsOn = Command(:turn_uploads_on)
    TurnUploadsOff = Command(:turn_uploads_off)

    # +uploads_since+: when uploads were last turned on, nil while off.
    context { { uploads_since: nil } }

    evolve(On) { |settings, evt| settings[:uploads_since] = evt.created_at }
    evolve(Off) { |settings, _evt| settings[:uploads_since] = nil }

    initial do
      command TurnUploadsOn => On
    end

    state On do
      command TurnUploadsOff => Off
    end

    state Off do
      command TurnUploadsOn => On
    end

    # When uploads were last turned on for +account+, or nil while they're
    # off: read from its history in +store+.
    # @return [Time, nil]
    def self.uploads_on_since(account = ACCOUNT, store: nil)
      load(store:, account:).context[:uploads_since]
    end
  end
end
