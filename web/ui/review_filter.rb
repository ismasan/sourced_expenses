# frozen_string_literal: true

module UI
  # The expense list's filters by whose category and VAT treatment an
  # expense has: Expenses::ExpenseList::CATEGORY_STATUSES and VAT_STATUSES
  # keys as a person reads them, in the order a review goes.
  module ReviewFilter
    Option = Data.define(:key, :label)

    CATEGORY = [
      Option.new('suggested', 'Suggested'),
      Option.new('chosen', 'Chosen'),
      Option.new('none', 'None yet')
    ].freeze

    VAT = [
      Option.new('suggested', 'Suggested'),
      Option.new('confirmed', 'Confirmed'),
      Option.new('none', 'None yet')
    ].freeze

    # category_status[] and vat_status[] query params: known statuses only, none if absent.
    CategoryParam = Types::Array[Types::String.options(CATEGORY.map(&:key))].default([].freeze)
    VatParam = Types::Array[Types::String.options(VAT.map(&:key))].default([].freeze)
  end
end
