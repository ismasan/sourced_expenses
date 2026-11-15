# frozen_string_literal: true

# Where uploaded documents live. A file's id is the MD5 digest of its bytes,
# so storing the same file twice is a no-op that returns the same id.
#
#   id = file_store.put('lunch.jpg', io_or_string)  # => "9e107d9d372bb6826bd81d3542a419d6"
#   file_store.read(id)                              # => FileStore::StoredFile
#
# FileStore::Disk is the only implementation so far. Another one (S3, say)
# answers the same two methods. Classes get the app's with `dep :file_store`
# (config/components/file_store.rb).
module FileStore
  # A stored file. +path+ is a local path to read it from.
  StoredFile = Data.define(:id, :filename, :path, :size)

  NotFound = Class.new(KeyError)

  ID = /\A[0-9a-f]{32}\z/
end
