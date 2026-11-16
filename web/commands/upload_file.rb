# frozen_string_literal: true

module Commands
  # A file posted from the upload form. Web only: App's handler stores the
  # file and dispatches Expenses::Expense::UploadDocument with its id. This
  # command is never stored itself: its payload holds a Tempfile.
  #
  # +file+ is a Sidereal::Types::UploadedFile, the struct Rack parses a
  # multipart part into (filename, type, tempfile...). The checks are
  # Expenses::Upload's, made the command's, so an upload that fails one never reaches the handler:
  # Sidereal streams the message back to the form's file field.
  UploadFile = Sidereal::Message.define('web.upload_file') do
    attribute :file, Sidereal::Types::UploadedFile
      # Not .where(type: Types::String.options(...)): it works, but its error
      # is Plumb's own ("must have attribute type === ..."), shown on the form.
      .check(Expenses::Upload::WRONG_TYPE) { Expenses::Upload.accepted_type?(it.type) }
      .check(Expenses::Upload::TOO_BIG) { Expenses::Upload.accepted_size?(it.tempfile.size) }
  end
end
