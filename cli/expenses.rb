# frozen_string_literal: true

require 'rack/mime'

# `bin/sid expenses`: the app's own commands. Registered by
# config/components/cli.rb, only when `sid` is running: the web app never
# loads this.
module CLI
  class Expenses < Sidereal::CLI::Command
    # `bin/sid expenses upload <paths...>`: each file as if dropped on the
    # upload form. Checked as the form checks them (type, by extension, and
    # size), stored, and its UploadDocument dispatched. A file that fails a
    # check is skipped and the rest go on; any skipped makes the exit status
    # non-zero.
    #
    # The running app scans them: without it, they wait in the store until
    # it starts.
    class Upload < Sidereal::CLI::Command
      self.description = 'Upload receipts and invoices to scan, as the upload form does'

      options do
        option '--reference-date <date>', 'Read dates on them against this day (YYYY-MM-DD), not today'
      end

      many :paths, 'PDFs or photos (JPEG, PNG or WebP)'

      def call
        paths = @paths || []
        raise Sidereal::CLI::Error, 'Name a file, e.g. `bin/sid expenses upload ~/receipts/lunch.pdf`' if paths.empty?

        reference_date = parse_date(@options[:reference_date])
        Sidereal::CLI.boot_app!
        skipped = paths.count { !upload(it, reference_date) }
        return if skipped.zero?

        raise Sidereal::CLI::Error, "#{skipped} of #{paths.size} not uploaded"
      end

      private

      # @return [Boolean] whether it was uploaded
      def upload(path, reference_date)
        return skip(path, 'No such file') unless File.file?(path)

        content_type = Rack::Mime.mime_type(File.extname(path).downcase, nil)
        problem = ::Expenses::Upload.problem(content_type:, size: File.size(path))
        return skip(path, problem) if problem

        command = File.open(path, 'rb') do |io|
          ::Expenses::Upload.store(config['file_store'], filename: File.basename(path), content_type:, io:,
                                                         filing_country: config['expenses.filing_country'], reference_date:)
        end
        Sidereal.dispatch!(command)
        terminal.print_line :title, 'Uploaded ', :reset, "#{path}  ", :key, submission_url(command.payload.expense_id)
        true
      end

      def skip(path, reason)
        terminal.print_line :error, 'Skipped ', :reset, "#{path}: #{reason}"
        false
      end

      def parse_date(value)
        value && Date.iso8601(value)
      rescue Date::Error
        raise Sidereal::CLI::Error, "--reference-date #{value.inspect} isn't a date (YYYY-MM-DD)"
      end

      def config = Sidereal.config

      # Where to watch it scan, on the app as falcon.rb serves it.
      def submission_url(expense_id)
        "http://#{ENV.fetch('HOST', 'localhost')}:#{ENV.fetch('PORT', '9292')}/submissions/#{expense_id}"
      end
    end

    self.description = 'Work with expenses: upload documents to scan'

    nested :command, { 'upload' => Upload }

    def call
      @command ? @command.call : print_usage
    end
  end
end
