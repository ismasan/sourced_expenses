# frozen_string_literal: true

module Expenses
  # A document to scan, from a file: what's accepted, and the
  # UploadDocument that stores it and starts its scan. Shared by the upload
  # form (UI::Components::UploadForm's UploadFile handler) and
  # `bin/sid expenses upload`.
  #
  #   problem = Upload.problem(content_type:, size:)  # => nil, or why not
  #   command = Upload.store(file_store, filename:, content_type:, io:, filing_country:)
  #   Sidereal.dispatch(command) unless Upload.uploaded?(command.payload.expense_id)
  #
  # The expense's id is the file's: the digest of its bytes. The same file
  # uploaded again is the same expense, which the machine only starts once,
  # so dispatching it again changes nothing either.
  module Upload
    # The types the scan reads, up to a size.
    ACCEPTED_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze
    MAX_BYTES = 20 * 1024 * 1024

    WRONG_TYPE = 'Upload a PDF or a photo (JPEG, PNG or WebP)'
    TOO_BIG = "That file is over #{MAX_BYTES / 1024 / 1024} MB".freeze

    def self.accepted_type?(content_type) = ACCEPTED_TYPES.include?(content_type)

    def self.accepted_size?(size) = size <= MAX_BYTES

    # Why a file can't be uploaded, as the form says it, or nil if it can.
    # @return [String, nil]
    def self.problem(content_type:, size:)
      return WRONG_TYPE unless accepted_type?(content_type)

      TOO_BIG unless accepted_size?(size)
    end

    # Stores the file and returns the command that starts its scan, for the
    # caller to dispatch. The file's id is its bytes' digest, and the
    # expense's is the file's: the same file twice is stored once, as one
    # expense.
    #
    # @param io [IO, String] the file's bytes
    # @param reference_date [Date, nil] the day to read dates against, today by default
    # @return [Expense::UploadDocument]
    def self.store(file_store, filename:, content_type:, io:, filing_country:, reference_date: nil)
      file_ref = file_store.put(filename, io)
      payload = { expense_id: file_ref, filename:, content_type:, file_ref:, filing_country:, reference_date: }.compact
      Expense::UploadDocument.new(payload:)
    end

    # Whether the expense +expense_id+ has been uploaded already: an
    # UploadDocument for it is in the store, scanned yet or not.
    def self.uploaded?(expense_id)
      selector = Sourced::Selector[Expense::UploadDocument].by(:expense_id)
      Sourced.store.read(selector.bind(expense_id:)).messages.any?
    end
  end
end
