# frozen_string_literal: true

require 'json'
require 'rack/mime'

# `bin/sid expenses`: the app's own commands. Registered by
# config/components/cli.rb, only when `sid` is running: the web app never
# loads this.
module CLI
  class Expenses < Sidereal::CLI::Command
    # `bin/sid expenses upload <paths...>`: each file as if dropped on the
    # upload form. Checked as the form checks them (type, by extension, and
    # size), stored, and its UploadDocument dispatched. A file uploaded
    # before is that expense already: it says so, and dispatches nothing. A file that fails a
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
        expense_id = command.payload.expense_id
        if ::Expenses::Upload.uploaded?(expense_id)
          terminal.print_line :title, 'Already uploaded ', :reset, "#{path}  ", :key, submission_url(expense_id)
        else
          Sidereal.dispatch!(command)
          terminal.print_line :title, 'Uploaded ', :reset, "#{path}  ", :key, submission_url(expense_id)
        end
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

    # `bin/sid expenses list`: expenses from the list the app shows
    # (Expenses::Submissions), newest first, filtered. A table to read, or
    # with --json one JSON object per line, for `bin/sid expenses dispatch`
    # (or jq) to take.
    #
    #   bin/sid expenses list --state filed,vat_needs_review --category-status suggested
    class List < Sidereal::CLI::Command
      self.description = 'List expenses, filtered: a table, or JSON lines to pipe into `expenses dispatch`'

      CATEGORY_STATUSES = %w[suggested chosen none].freeze

      options do
        # Submissions::STATES' keys, written out: this file loads with the
        # components, before the app's classes can.
        option '--state <states>', 'Only in these states, comma-separated: scanning, reviewing, rejected, ' \
                                   'scan_failed, vat_needs_review, filed, discarded, voided'
        option '--category <keys>', 'Only with these categories, comma-separated (keys, as `--json` prints them)'
        option '--category-status <status>', "Only those whose category is #{CATEGORY_STATUSES.join(', ')} (none: no category yet)"
        option '--search <text>', 'Only those whose description, vendor, filename or category has every word, as the search box finds them'
        option '--from <date>', 'Only dated on or after this day (YYYY-MM-DD)'
        option '--to <date>', 'Only dated on or before this day (YYYY-MM-DD)'
        option '--limit <n>', 'At most this many'
        option '--json', 'One JSON object per line, with every field'
      end

      def call
        filters = parse_filters
        Sidereal::CLI.boot_app!
        rows = dataset(**filters).map { record(::Expenses::Submissions.row(it)) }
        @options[:json] ? rows.each { output.puts JSON.generate(it) } : print_table(rows)
      end

      private

      def parse_filters
        states = list(:state)
        unknown = states - ::Expenses::Submissions::STATES.keys
        raise Sidereal::CLI::Error, "No such state: #{unknown.join(', ')}" if unknown.any?

        categories = list(:category)
        unknown = categories - ::Expenses::CATEGORIES.keys
        raise Sidereal::CLI::Error, "No such category: #{unknown.join(', ')}" if unknown.any?

        status = @options[:category_status]
        if status && !CATEGORY_STATUSES.include?(status)
          raise Sidereal::CLI::Error, "--category-status is one of #{CATEGORY_STATUSES.join(', ')}"
        end

        limit = @options[:limit] && Integer(@options[:limit], 10, exception: false)
        raise Sidereal::CLI::Error, '--limit is a number' if @options[:limit] && !limit&.positive?

        search = @options[:search].to_s.strip
        { states:, categories:, status:, search: (search unless search.empty?), from: date(:from), to: date(:to), limit: }
      end

      def dataset(states:, categories:, status:, search:, from:, to:, limit:)
        ds = ::Expenses::Submissions.in_states(Sidereal.config['db'], states, categories:, search:, from:, to:)
        ds = case status
             when 'suggested' then ds.exclude(category: nil).where(category_chosen: false)
             when 'chosen' then ds.where(category_chosen: true)
             when 'none' then ds.where(category: nil)
             else ds
             end
        ds = ds.limit(limit) if limit
        ds.reverse(:uploaded_at)
      end

      # Where the row is, as one of Submissions::STATES' keys.
      def state_of(row)
        return 'vat_needs_review' if row.in?('filed.vat_needs_review')

        (::Expenses::Submissions::STATES.keys & row.machine).first || 'scanning'
      end

      def record(row)
        {
          expense_id: row.expense_id, state: state_of(row), filename: row.filename, description: row.description,
          total_cents: row.total_cents, currency: row.currency, incurred_on: row.incurred_on&.iso8601,
          category: row.category, category_chosen: row.category_chosen
        }
      end

      def print_table(rows)
        rows.each do |r|
          total = r[:total_cents] ? format('%.2f %s', r[:total_cents] / 100.0, r[:currency]) : ''
          category = r[:category] ? "#{::Expenses.category_label(r[:category])}#{r[:category_chosen] ? '' : ' (suggested)'}" : ''
          terminal.print_line :key, r[:expense_id], :reset, '  ', r[:state].ljust(16), (r[:incurred_on] || '').ljust(12),
                              total.rjust(14), '  ', category.ljust(40), (r[:description] || r[:filename]).to_s
        end
        terminal.print_line :reset, "#{rows.size} #{rows.size == 1 ? 'expense' : 'expenses'}"
      end

      def list(key) = @options[key].to_s.split(',').map(&:strip).reject(&:empty?)

      def date(key)
        value = @options[key]
        value && Date.iso8601(value)
      rescue Date::Error
        raise Sidereal::CLI::Error, "--#{key} #{value.inspect} isn't a date (YYYY-MM-DD)"
      end
    end

    # `bin/sid expenses dispatch <command> [--attr value...]`: one command
    # for each JSON object on stdin (as `expenses list --json` prints them),
    # its payload taken from the object's fields that the command has, and
    # from attributes given here, which win. As `bin/sid commands dispatch`
    # takes them, and in one boot of the app rather than one each.
    #
    # Every command is validated first: if any is invalid, nothing is
    # dispatched and the errors are listed. --dry-run lists what would be
    # dispatched (and isn't an attribute of any command).
    #
    #   bin/sid expenses list --state filed --category-status suggested --json |
    #     bin/sid expenses dispatch expenses.choose_category
    #   bin/sid expenses list --category general --json | bin/sid expenses dispatch expenses.choose_category --category office_costs
    class Dispatch < Sidereal::CLI::Commands::Dispatch
      self.description = 'Send a command for each JSON line on stdin, e.g. from `expenses list --json`'

      DRY_RUN = '--dry-run'

      def initialize(*, input: $stdin, **)
        super(*, **)
        @input = input
      end

      def call
        attributes = @attributes || []
        return super if (attributes & HELP).any?
        raise Sidereal::CLI::Error, 'Name a command, e.g. `bin/sid expenses dispatch expenses.choose_category`' unless @class_name

        dry_run = attributes.include?(DRY_RUN)
        attributes -= [DRY_RUN]
        raise Sidereal::CLI::Error, 'Pipe JSON lines in, e.g. from `bin/sid expenses list --json`' if @input.tty?

        Sidereal::CLI.boot_app!
        entry = Sidereal::CLI::Commands.find!(@class_name)
        raise Sidereal::CLI::Error, "Nothing handles #{entry.type}, so it would never run" if entry.handlers.empty?

        command_class = entry.command_class
        schema = command_class::Payload.to_json_schema
        fields = schema.fetch('properties', {}).keys.map(&:to_sym)
        given = Sidereal::CLI::Commands::Arguments.new(schema).parse(attributes)
        codec = forms_codec(command_class)

        commands, errors = [], []
        each_line do |record, number|
          params = stringify(record.transform_keys(&:to_sym).slice(*fields)).merge(given)
          result = codec.resolve(command_class.type, params)
          if result.valid?
            commands << command_class.new(payload: result.value)
          else
            errors << "Line #{number}: #{error_lines(result.errors, params).join('; ')}"
          end
        end
        if errors.any?
          raise Sidereal::CLI::Error, ["Nothing dispatched. Invalid #{entry.type}:", *errors.map { "  #{it}" }].join("\n")
        end

        commands.each do |command|
          Sidereal.dispatch!(command) unless dry_run
          terminal.print_line :title, dry_run ? 'Would dispatch ' : 'Dispatched ', :reset, "#{entry.type}  ",
                              :key, command.payload.to_h.map { |k, v| "#{k}: #{v}" }.join('  ')
        end
        terminal.print_line :reset, "#{commands.size} #{commands.size == 1 ? 'command' : 'commands'}#{' (dry run)' if dry_run}"
      end

      private

      def each_line
        @input.each_line.with_index(1) do |line, number|
          next if line.strip.empty?

          record = JSON.parse(line)
          raise Sidereal::CLI::Error, "Line #{number} isn't a JSON object" unless record.is_a?(Hash)

          yield record, number
        rescue JSON::ParserError
          raise Sidereal::CLI::Error, "Line #{number} isn't JSON"
        end
      end

      # As form fields arrive, which is what the codec converts from: nils
      # left out, scalars as strings.
      def stringify(value)
        case value
        when Hash then value.compact.transform_values { stringify(it) }
        when Array then value.map { stringify(it) }
        else value.to_s
        end
      end
    end

    self.description = 'Work with expenses: upload documents to scan, list them, send them commands'

    nested :command, { 'upload' => Upload, 'list' => List, 'dispatch' => Dispatch }

    def call
      @command ? @command.call : print_usage
    end
  end
end
