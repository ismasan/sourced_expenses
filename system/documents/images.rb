# frozen_string_literal: true

require 'open3'

module Documents
  # Shrinks a photo before it goes to the model, with ImageMagick's `magick`.
  # The original is never sent when it's over MAX_BYTES: if it can't be
  # shrunk below that, preparing fails.
  module Images
    MAX_BYTES = 500 * 1024
    # [longest side, JPEG quality], tried in turn until one fits.
    PASSES = [[1600, 80], [1200, 60], [1000, 45]].freeze

    Error = Class.new(StandardError)

    def self.small_enough?(path) = File.size(path) <= MAX_BYTES

    # Writes a JPEG of +source+ to +destination+, at most MAX_BYTES.
    # @raise [Error] when ImageMagick fails or can't get it small enough
    def self.shrink(source, destination)
      PASSES.each do |side, quality|
        magick(source, '-auto-orient', '-resize', "#{side}x#{side}>", '-strip', '-quality', quality.to_s, destination)
        return destination if small_enough?(destination)
      end
      raise Error, "Couldn't shrink the image below #{MAX_BYTES / 1024} KB"
    end

    def self.magick(source, *options, destination)
      # [0]: the first frame, for an animated or multi-page image
      _out, status = Open3.capture2e('magick', "#{source}[0]", *options, "jpeg:#{destination}")
      raise Error, "ImageMagick couldn't read the image" unless status.success?
    rescue Errno::ENOENT
      raise Error, 'ImageMagick (magick) is not installed'
    end
  end
end
