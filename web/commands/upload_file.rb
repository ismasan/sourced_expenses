# frozen_string_literal: true

module Commands
  # What the upload form takes: the types the scan reads, up to a size.
  ACCEPTED_UPLOAD_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze
  MAX_UPLOAD_BYTES = 20 * 1024 * 1024

  # A file posted from the upload form. Web only: App's handler stores the
  # file and dispatches Expenses::Expense::UploadDocument with its id. This
  # command is never stored itself: its payload holds a Tempfile.
  #
  # +file+ is a Sidereal::Types::UploadedFile, the struct Rack parses a
  # multipart part into (filename, type, tempfile...). The checks are the
  # command's, so an upload that fails one never reaches the handler:
  # Sidereal streams the message back to the form's file field.
  UploadFile = Sidereal::Message.define('web.upload_file') do
    attribute :file, Sidereal::Types::UploadedFile
      # Not .where(type: Types::String.options(...)): it works, but its error
      # is Plumb's own ("must have attribute type === ..."), shown on the form.
      .check('Upload a PDF or a photo (JPEG, PNG or WebP)') { ACCEPTED_UPLOAD_TYPES.include?(it.type) }
      .check("That file is over #{MAX_UPLOAD_BYTES / 1024 / 1024} MB") { it.tempfile.size <= MAX_UPLOAD_BYTES }
  end
end
