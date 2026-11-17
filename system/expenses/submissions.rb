# frozen_string_literal: true

require 'json'

module Expenses
  # The read model behind the home page's list: one row per uploaded
  # document, in the `submissions` table, rewritten whenever its expense
  # moves. Where the machine is (its paths) comes from the state events'
  # entered and exited paths, so the list never loads a machine.
  #
  # Each row is in the `submissions_search` full-text index too (an FTS5
  # table, trigram tokenizer): its description, vendor, filename and
  # category, for #search.
  #
  # Sidereal publishes Submissions::Projected after every committed batch,
  # which is what the page reacts to.
  class Submissions < Sourced::Projector::StateStored
    partition_by expense_id: Types::ExpenseID

    dep :db

    Row = ::Data.define(:expense_id, :filename, :machine, :failure, :rejection, :description,
                        :total_cents, :currency, :incurred_on, :category, :category_chosen,
                        :uploaded_at, :updated_at) do
      def in?(path) = machine.include?(path)
    end

    COLUMNS = %i[filename content_type file_ref machine failure rejection description vendor
                 total_cents currency incurred_on category category_chosen uploaded_at updated_at].freeze

    # The machine's paths are a JSON array: whether +path+ is one of them.
    def self.in_path(path)
      Sequel.lit('EXISTS (SELECT 1 FROM json_each(submissions.machine) WHERE value = ?)', path)
    end

    # Where an expense is, for filtering: one key per state a person tells
    # apart, each a condition on the machine's paths. The top-level states
    # exclude each other, so every row is in exactly one. (No paths yet:
    # the upload is still being stored, which counts as scanning.)
    STATES = {
      'scanning' => Sequel.|(in_path('scanning'), { machine: '[]' }),
      'reviewing' => in_path('reviewing'),
      'rejected' => in_path('rejected'),
      'scan_failed' => in_path('scan_failed'),
      'vat_needs_review' => in_path('filed.vat_needs_review'),
      'filed' => Sequel.&(in_path('filed'), Sequel.~(in_path('filed.vat_needs_review'))),
      'discarded' => in_path('discarded'),
      'voided' => in_path('voided')
    }.freeze

    # The states waiting for a person.
    NEEDS_YOU = %w[reviewing vat_needs_review rejected scan_failed].freeze

    # Rows in any of +states+ (STATES keys; all rows when there are none),
    # with any of +categories+ (CATEGORIES keys; any category or none, when
    # there are none), dated +from+ to +to+ (either may be nil, for no
    # bound), matching +search+ (see .search; nil or blank for any). A
    # range leaves out rows with no date yet: still scanning, or never read.
    def self.in_states(db, states = [], categories: [], from: nil, to: nil, search: nil)
      conditions = STATES.values_at(*(STATES.keys & states))
      ds = conditions.empty? ? db[:submissions] : db[:submissions].where(Sequel.|(*conditions))
      ds = ds.where(category: categories) if categories.any?
      ds = ds.where { incurred_on >= from } if from
      ds = ds.where { incurred_on <= to } if to
      ids = search(db, search)
      ds = ds.where(expense_id: ids) if ids
      ds
    end

    # The ids of the rows matching +text+, as a dataset to filter by
    # (`where(expense_id: ...)`, here or in another table), or nil for a
    # blank +text+: no filter. Every word in it must be somewhere in the
    # description, vendor, filename or category, as any part of a word,
    # whatever its case. Words of 3 characters or more are matched in the
    # index, ignoring accents too ("cafe" finds "Café"); shorter ones, which
    # the trigram index can't, as plain substrings.
    #
    # Words are quoted as FTS5 strings, so nothing typed is query syntax.
    # @return [Sequel::Dataset, nil]
    def self.search(db, text)
      words = text.to_s.split
      return if words.empty?

      long, short = words.partition { it.length >= 3 }
      ds = db[:submissions_search].select(:expense_id)
      ds = ds.where(Sequel.lit('submissions_search MATCH ?', long.map { %("#{it.gsub('"', '""')}") }.join(' '))) if long.any?
      short.each { ds = ds.where(Sequel.like(:body, "%#{ds.escape_like(it)}%", case_insensitive: false)) }
      ds
    end

    # One page of +states+ and +categories+, dated +from+ to +to+, matching +search+.
    # @return [Array(Array<Row>, Integer)] the page's rows, and how many there are in all
    def self.page(db, states: [], categories: [], from: nil, to: nil, search: nil, page: 1, per_page: 25)
      ds = in_states(db, states, categories:, from:, to:, search:)
      rows = ds.reverse(:uploaded_at).limit(per_page, (page - 1) * per_page).map { row(it) }
      [rows, ds.count]
    end

    # How many rows with +categories+, dated +from+ to +to+, matching
    # +search+, are in each of STATES.
    # @return [Hash{String => Integer}]
    def self.counts(db, categories: [], from: nil, to: nil, search: nil)
      STATES.to_h { |key, _| [key, in_states(db, [key], categories:, from:, to:, search:).count] }
    end

    # How many rows in +states+, dated +from+ to +to+, matching +search+,
    # have each category: only categories some row has.
    # @return [Hash{String => Integer}]
    def self.category_counts(db, states: [], from: nil, to: nil, search: nil)
      in_states(db, states, from:, to:, search:).exclude(category: nil).group_and_count(:category)
                                                .to_h { [it[:category], it[:count]] }
    end

    # The latest uploads first.
    def self.recent(db, limit: 50)
      db[:submissions].reverse(:uploaded_at).limit(limit).map { row(it) }
    end

    def self.row(row) = Row.new(**row.slice(*Row.members), machine: JSON.parse(row[:machine]))

    # The group's offsets were rewound (`bin/sid sourced groups reset
    # expenses.submissions`): every row goes, and it builds them again from
    # the start of the store once started.
    def self.on_reset
      db = Sidereal.config['db']
      db[:submissions].delete
      db[:submissions_search].delete
    end

    context { { machine: [], category_chosen: false } }

    load_context do |partition|
      row = db[:submissions].where(expense_id: partition[:expense_id]).first
      row&.merge(machine: JSON.parse(row[:machine]))
    end

    Expense.transition_classes.each do |klass|
      evolve klass do |row, evt|
        row[:expense_id] = evt.payload.expense_id
        row[:machine] = (row[:machine] - evt.payload.exited) | evt.payload.entered
        row[:updated_at] = evt.created_at
      end
    end

    evolve Expense::DocumentUploaded do |row, evt|
      row.merge!(evt.payload.to_h.slice(:expense_id, :filename, :content_type, :file_ref))
      row[:uploaded_at] = evt.created_at
    end

    # A rescan starts from nothing.
    evolve Expense::ScanRequested do |row, _evt|
      row.merge!(failure: nil, rejection: nil, description: nil, vendor: nil, total_cents: nil, currency: nil,
                 incurred_on: nil)
    end

    evolve Expense::StepFailed do |row, evt|
      row[:failure] = evt.payload.reason
    end

    evolve Expense::Scanning::DocumentVerified do |row, evt|
      row[:rejection] = evt.payload.explanation unless evt.payload.is_invoice_or_receipt
    end

    evolve Expense::Scanning::ExtractionRecorded do |row, evt|
      total = evt.payload.total_amount
      row.merge!(
        description: evt.payload.description,
        vendor: evt.payload.vendor_name,
        total_cents: total && (total * 100).round,
        currency: evt.payload.currency,
        incurred_on: Types.iso_date(evt.payload.date)
      )
    end

    evolve Expense::Scanning::DateRechecked do |row, evt|
      row[:incurred_on] = Types.iso_date(evt.payload.corrected_date) if evt.payload.corrected_date
    end

    evolve Expense::Scanning::TextCleaned do |row, evt|
      row[:description] = evt.payload.description
    end

    evolve Expense::ExpenseFiled do |row, evt|
      row.merge!(
        description: evt.payload.description,
        total_cents: evt.payload.net_price_cents + evt.payload.tax_amount_cents,
        currency: evt.payload.currency,
        incurred_on: evt.payload.incurred_on
      )
    end

    # The model's suggestion stands until a person chooses.
    evolve Expense::CategorySuggested do |row, evt|
      row[:category] = evt.payload.category unless row[:category_chosen]
    end

    evolve Expense::CategoryChosen do |row, evt|
      row[:category] = evt.payload.category
      row[:category_chosen] = true
    end

    sync do |context:, **|
      next unless context[:filename]

      row = context.slice(*COLUMNS).merge(machine: JSON.generate(context[:machine]))
      db[:submissions].insert_conflict(target: :expense_id, update: row)
                      .insert(row.merge(expense_id: context[:expense_id]))
      # FTS5 tables have no upsert: the old entry goes, the new one in.
      index = db[:submissions_search]
      index.where(expense_id: context[:expense_id]).delete
      index.insert(expense_id: context[:expense_id], body: Submissions.search_body(context))
    end

    # What a row is found by, a line each.
    def self.search_body(row)
      category = row[:category] && Expenses.category_label(row[:category])
      [row[:description], row[:vendor], row[:filename], category].compact.join("\n")
    end
  end
end
