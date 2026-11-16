# frozen_string_literal: true

# Uploaded documents (system/file_store.rb), under storage/ by default.
# Classes get it with `dep :file_store`. To keep them elsewhere:
#
#   Sidereal.config.env('UPLOADS_DIR' => 'file_store.root')
Sidereal.config.tap do |c|
  c.declare('file_store.root', Sidereal::Types::String) { 'storage/uploads' }
  c.declare('file_store', Sidereal::Types::Interface[:put, :read])
  c.config!('file_store', ['file_store.root']) { |root| FileStore::Disk.new(root:) }

  # Previews of uploads (system/thumbnails.rb), made on first request.
  c.declare('thumbnails.root', Sidereal::Types::String) { 'storage/thumbnails' }
  c.declare('thumbnails', Thumbnails)
  c.config!('thumbnails', ['thumbnails.root']) { |root| Thumbnails.new(root:) }

  # The country of the company whose books these are: every upload is filed
  # there, and it decides the VAT treatment. One company per app, for now.
  # An ISO code, GB unless FILING_COUNTRY says otherwise.
  c.declare('expenses.filing_country', Sidereal::Types::String) { ENV.fetch('FILING_COUNTRY', 'GB') }
end
