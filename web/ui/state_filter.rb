# frozen_string_literal: true

module UI
  # The expense list's filter by state: Expenses::ExpenseList::STATES keys
  # as a person reads them, each with the stage its colour comes from (see
  # UI::Status). In the order an expense's states are listed: what needs a
  # person first, as on the home page.
  module StateFilter
    Option = Data.define(:key, :label, :stage)

    OPTIONS = [
      Option.new('reviewing', 'Ready to review', :yours),
      Option.new('reviewed', 'Ready to file', :yours),
      Option.new('filed', 'Filed', :done),
      Option.new('voided', 'Voided', :closed)
    ].freeze

    # A state[] query param: known states only, none if absent.
    Param = Types::Array[Types::String.options(OPTIONS.map(&:key))].default([].freeze)
  end
end
