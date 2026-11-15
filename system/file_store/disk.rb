# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'stringio'

module FileStore
  # Files on the local disk, under +root+, by id:
  #
  #   <root>/9e/9e107d9d372bb6826bd81d3542a419d6/data.jpg   the bytes
  #   <root>/9e/9e107d9d372bb6826bd81d3542a419d6/meta.json  {"filename": "lunch.jpg", "data": "data.jpg"}
  #
  # The client's filename never reaches a path: only its extension does, so
  # the stored file opens in whatever reads that kind. Both files are written to a
  # temporary name and moved into place, and meta.json goes last, so a file
  # without one was never finished. The same bytes put twice under different
  # names keep the first name, and its extension.
  class Disk
    CHUNK = 64 * 1024
    EXTENSION = /\A\.[a-z0-9]{1,10}\z/

    attr_reader :root

    def initialize(root:)
      @root = File.expand_path(root)
    end

    # @param filename [String] the name the file was uploaded with
    # @param data [String, #read] its bytes, or an IO to stream them from
    # @return [String] the file's id
    def put(filename, data)
      io = data.respond_to?(:read) ? data : StringIO.new(data.to_s)
      FileUtils.mkdir_p(tmp_dir)
      tmp = File.join(tmp_dir, SecureRandom.hex(8))
      digest = Digest::MD5.new

      File.open(tmp, 'wb') do |out|
        while (chunk = io.read(CHUNK))
          digest << chunk
          out.write(chunk)
        end
      end

      id = digest.hexdigest
      return id.tap { File.delete(tmp) } if stored?(id)

      filename = File.basename(filename.to_s)
      data = "data#{extension(filename)}"
      FileUtils.mkdir_p(dir_for(id))
      File.rename(tmp, File.join(dir_for(id), data))
      write_meta(id, filename:, data:)
      id
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    # @param id [String]
    # @return [StoredFile]
    # @raise [NotFound] for an id that isn't stored
    def read(id)
      raise NotFound, "no file #{id.inspect}" unless ID.match?(id.to_s) && stored?(id)

      meta = JSON.parse(File.read(meta_path(id)))
      # Files stored before extensions were kept are plain 'data'.
      path = File.join(dir_for(id), meta.fetch('data', 'data'))
      StoredFile.new(id:, filename: meta.fetch('filename'), path:, size: File.size(path))
    end

    private

    def stored?(id) = File.exist?(meta_path(id))

    # ".pdf" for "Receipt.PDF"; nothing for a name without a plain one.
    def extension(filename)
      ext = File.extname(filename).downcase
      EXTENSION.match?(ext) ? ext : ''
    end

    # Linked into place rather than renamed: when two processes store the
    # same bytes at once, the first meta.json wins and the second is dropped.
    def write_meta(id, meta)
      tmp = File.join(tmp_dir, SecureRandom.hex(8))
      File.write(tmp, JSON.generate(meta))
      File.link(tmp, meta_path(id))
    rescue Errno::EEXIST
      nil
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def tmp_dir = File.join(root, 'tmp')
    def dir_for(id) = File.join(root, id[0, 2], id)
    def meta_path(id) = File.join(dir_for(id), 'meta.json')
  end
end
