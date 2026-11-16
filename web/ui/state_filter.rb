# frozen_string_literal: true

module UI
  # The expense list's filter by state: Expenses::Submissions::STATES keys
  # as a person reads them, each with the stage its colour comes from (see
  # UI::Status). In the order a submission's states are listed: what needs
  # a person first, as on the home page.
  module StateFilter
    Option = Data.define(:key, :label, :stage)

    OPTIONS = [
      Option.new('reviewing', 'Ready to review', :yours),
      Option.new('vat_needs_review', 'Check the VAT', :yours),
      Option.new('rejected', 'Not a receipt', :problem),
      Option.new('scan_failed', 'Scan failed', :problem),
      Option.new('scanning', 'Being read', :working),
      Option.new('filed', 'Filed', :done),
      Option.new('discarded', 'Discarded', :closed),
      Option.new('voided', 'Voided', :closed)
    ].freeze

    # The known states among +keys+, from a query string or a signal.
    # @return [Array<String>]
    def self.parse(keys)
      Array(keys).map(&:to_s) & OPTIONS.map(&:key)
    end
  end
end
