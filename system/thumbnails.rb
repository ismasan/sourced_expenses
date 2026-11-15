# frozen_string_literal: true

require 'fileutils'
require 'open3'

# Small JPEG previews of stored files, made with ImageMagick the first time
# they're asked for and kept under +root+ by file id. A PDF's preview is its
# first page (ImageMagick renders it with Ghostscript).
#
#   thumbnails.path_for(file_store.read(id)) # => "storage/thumbnails/<id>.jpg"
class Thumbnails
  SIZE = 480

  Error = Class.new(StandardError)

  def initialize(root:)
    @root = File.expand_path(root)
  end

  # @param file [FileStore::StoredFile]
  # @return [String] the preview's path
  # @raise [Error] when ImageMagick can't make one
  def path_for(file)
    path = File.join(@root, "#{file.id}.jpg")
    return path if File.exist?(path)

    FileUtils.mkdir_p(@root)
    tmp = "#{path}.#{Process.pid}.tmp"
    _out, status = Open3.capture2e('magick', '-density', '96', "#{file.path}[0]", '-auto-orient',
                                   '-thumbnail', "#{SIZE}x#{SIZE}>", '-background', 'white', '-flatten',
                                   '-quality', '80', "jpeg:#{tmp}")
    raise Error, "Couldn't make a preview of #{file.filename}" unless status.success?

    File.rename(tmp, path)
    path
  rescue Errno::ENOENT
    raise Error, 'ImageMagick (magick) is not installed'
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end
end
