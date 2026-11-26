# frozen_string_literal: true

require 'json'

module Expenses
  # The read model behind the expense lists: one row per expense, however
  # it was drafted, in the `expenses` table, rewritten whenever it moves.
  # Where the machine is (its paths) comes from the state events' entered
  # and exited paths, so the list never loads a machine. Documents still
  # being read, or that couldn't be, are DocumentList's.
  #
  # +source+ is the system it was imported from, if any; +uploaded_to+, the
  # systems it's uploaded to now (Expense::ExpenseUploaded, until
  # ExpenseUploadDeleted); +upload_failed_to+, those its latest upload or
  # deletion failed for (ExpenseUploadFailed, until one succeeds).
  #
  # Each row is in the `expenses_search` full-text index too (an FTS5
  # table, trigram tokenizer): its description, vendor and category, for
  # #search.
  #
  # A discarded expense leaves both: it's gone from the lists and search.
  #
  # Sidereal publishes ExpenseList::Projected after every committed batch,
  # which is what the pages react to.
  class ExpenseList < Sourced::Projector::StateStored
    partition_by expense_id: Types::ExpenseID

    dep :db

    Row = ::Data.define(:expense_id, :document_id, :source, :uploaded_to, :upload_failed_to, :machine, :description, :vendor, :total_cents, :currency,
                        :incurred_on, :category, :category_chosen, :vat_treatment, :vat_confirmed,
                        :filing_country, :created_at, :updated_at) do
      def in?(path) = machine.include?(path)
      def uploaded_to?(destination) = uploaded_to.include?(destination)
      def upload_failed_to?(destination) = upload_failed_to.include?(destination)
    end

    COLUMNS = %i[document_id source uploaded_to upload_failed_to machine description vendor total_cents currency incurred_on category
                 category_chosen filing_country vat_treatment vat_confirmed created_at updated_at].freeze

    # The machine's paths are a JSON array: whether +path+ is one of them.
    def self.in_path(path)
      Sequel.lit('EXISTS (SELECT 1 FROM json_each(expenses.machine) WHERE value = ?)', path)
    end

    # Where an expense is, for filtering: one key per state a person tells
    # apart, each a condition on the machine's paths. The top-level states
    # exclude each other, so every row is in exactly one. (Discarded ones
    # have no row.)
    STATES = {
      'reviewing' => in_path('reviewing'),
      'reviewed' => in_path('reviewed'),
      'filed' => in_path('filed'),
      'voided' => in_path('voided')
    }.freeze

    # The states waiting for a person.
    NEEDS_YOU = %w[reviewing reviewed].freeze

    # Whose category it is: the model's suggestion, a person's choice, or
    # none yet (still suggesting, the model failed, or nothing to go on).
    CATEGORY_STATUSES = {
      'suggested' => Sequel.&(Sequel.~(category: nil), { category_chosen: false }),
      'chosen' => { category_chosen: true },
      'none' => { category: nil }
    }.freeze

    # Whose VAT treatment it is: the rule's suggestion, a person's, or none
    # yet (nothing in the draft to suggest one from).
    VAT_STATUSES = {
      'suggested' => Sequel.&(Sequel.~(vat_treatment: nil), { vat_confirmed: false }),
      'confirmed' => { vat_confirmed: true },
      'none' => { vat_treatment: nil }
    }.freeze

    # Rows in any of +states+ (STATES keys; all rows when there are none),
    # with any of +categories+ (CATEGORIES keys; any category or none, when
    # there are none), in any of +category_statuses+ (CATEGORY_STATUSES
    # keys) and any of +vat_statuses+ (VAT_STATUSES keys; either, none for
    # any), filed in any of +filing_countries+ (ISO 3166-1 alpha-2 codes;
    # any, for none), dated +from+ to +to+ (either may be nil, for no
    # bound), matching +search+ (see .search; nil or blank for any). A
    # range leaves out rows with no date yet: none in the draft.
    def self.in_states(db, states = [], categories: [], category_statuses: [], vat_statuses: [], filing_countries: [],
                       from: nil, to: nil, search: nil)
      ds = any_of(db[:expenses], STATES, states)
      ds = any_of(ds, CATEGORY_STATUSES, category_statuses)
      ds = any_of(ds, VAT_STATUSES, vat_statuses)
      ds = ds.where(category: categories) if categories.any?
      ds = ds.where(filing_country: filing_countries) if filing_countries.any?
      ds = ds.where { incurred_on >= from } if from
      ds = ds.where { incurred_on <= to } if to
      ids = search(db, search)
      ds = ds.where(expense_id: ids) if ids
      ds
    end

    # +ds+ where any of +conditions+ named by +keys+ holds: all of it for none.
    def self.any_of(ds, conditions, keys)
      chosen = conditions.values_at(*(conditions.keys & keys))
      chosen.empty? ? ds : ds.where(Sequel.|(*chosen))
    end
    private_class_method :any_of

    # The ids of the rows matching +text+, as a dataset to filter by
    # (`where(expense_id: ...)`, here or in another table), or nil for a
    # blank +text+: no filter. Every word in it must be somewhere in the
    # description, vendor or category, as any part of a word,
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
      ds = db[:expenses_search].select(:expense_id)
      ds = ds.where(Sequel.lit('expenses_search MATCH ?', long.map { %("#{it.gsub('"', '""')}") }.join(' '))) if long.any?
      # Lowercased both sides: Sequel turns SQLite's case_sensitive_like on.
      short.each { ds = ds.where(Sequel.like(Sequel.function(:lower, :body), "%#{ds.escape_like(it.downcase)}%")) }
      ds
    end

    # One page of the rows .in_states finds for +filters+.
    # @return [Array(Array<Row>, Integer)] the page's rows, and how many there are in all
    def self.page(db, states: [], page: 1, per_page: 25, **filters)
      ds = in_states(db, states, **filters)
      rows = ds.reverse(:created_at).limit(per_page, (page - 1) * per_page).map { row(it) }
      [rows, ds.count]
    end

    # How many of the rows .in_states finds for +filters+ (all but states)
    # are in each of STATES.
    # @return [Hash{String => Integer}]
    def self.counts(db, **filters)
      STATES.to_h { |key, _| [key, in_states(db, [key], **filters).count] }
    end

    # The status filters .in_states takes, by keyword.
    STATUS_FILTERS = { category_statuses: CATEGORY_STATUSES, vat_statuses: VAT_STATUSES }.freeze

    # How many of the rows .in_states finds for +filters+ (all but +filter+,
    # a STATUS_FILTERS key) are in each of its statuses.
    # @return [Hash{String => Integer}]
    def self.status_counts(db, filter, states: [], **filters)
      STATUS_FILTERS.fetch(filter).to_h { |status, _| [status, in_states(db, states, **filters, filter => [status]).count] }
    end

    # How many of the rows .in_states finds for +filters+ (all but
    # categories) have each category: only categories some row has.
    # @return [Hash{String => Integer}]
    def self.category_counts(db, states: [], **filters)
      in_states(db, states, **filters).exclude(category: nil).group_and_count(:category)
                                       .to_h { [it[:category], it[:count]] }
    end

    # The latest first.
    def self.recent(db, limit: 50)
      db[:expenses].reverse(:created_at).limit(limit).map { row(it) }
    end

    def self.row(row)
      Row.new(**row.slice(*Row.members), **JSON_COLUMNS.to_h { [it, JSON.parse(row[it])] })
    end

    # The group's offsets were rewound (`bin/sid sourced groups reset
    # expenses.expense_list`): every row goes, and it builds them again from
    # the start of the store once started.
    def self.on_reset
      db = Sidereal.config['db']
      db[:expenses].delete
      db[:expenses_search].delete
    end

    # Columns holding JSON arrays.
    JSON_COLUMNS = %i[machine uploaded_to upload_failed_to].freeze

    context { { machine: [], uploaded_to: [], upload_failed_to: [], category_chosen: false, vat_confirmed: false } }

    load_context do |partition|
      row = db[:expenses].where(expense_id: partition[:expense_id]).first
      row&.merge(JSON_COLUMNS.to_h { [it, JSON.parse(row[it])] })
    end

    Expense.transition_classes.each do |klass|
      evolve klass do |row, evt|
        row[:expense_id] = evt.payload.expense_id
        row[:machine] = (row[:machine] - evt.payload.exited) | evt.payload.entered
        row[:updated_at] = evt.created_at
      end
    end

    # Its figures, drafted, redrafted (its document read again), entered or
    # imported (or changed at its source while in review): what they say,
    # and the VAT treatment suggested for them (the source's, or the
    # rule's), unless a person has confirmed one. An imported expense's
    # category is its source's, until a person chooses one.
    FIGURES = proc do |row, evt|
      p = evt.payload.to_h
      row[:created_at] ||= evt.created_at
      row.merge!(
        expense_id: p[:expense_id], filing_country: p[:filing_country], description: p[:description],
        vendor: p[:vendor], currency: p[:currency], incurred_on: p[:incurred_on],
        total_cents: p[:net_price_cents] && (p[:net_price_cents] + p[:tax_amount_cents].to_i)
      )
      unless row[:vat_confirmed]
        row[:vat_treatment] = ExpenseState.suggested_vat_treatment(p, filing_country: p[:filing_country],
                                                                      source_vat_treatment: p[:vat_treatment])
      end
      row[:source] = p[:source] if p[:source]
      row[:category] = p[:category] if p[:category] && !row[:category_chosen]
    end
    evolve Expense::ExpenseDrafted, &FIGURES
    evolve Expense::ExpenseRedrafted, &FIGURES
    evolve Expense::ExpenseImported, &FIGURES
    evolve Expense::ImportedExpenseChanged, &FIGURES
    evolve Expense::ExpenseEntered, &FIGURES

    evolve Expense::DocumentAttached do |row, evt|
      row[:document_id] = evt.payload.document_id
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

    evolve Expense::VatTreatmentConfirmed do |row, evt|
      row[:vat_treatment] = evt.payload.treatment
      row[:vat_confirmed] = true
    end

    evolve Expense::ExpenseUploaded do |row, evt|
      row[:uploaded_to] |= [evt.payload.destination]
      row[:upload_failed_to] -= [evt.payload.destination]
    end

    evolve Expense::ExpenseUploadFailed do |row, evt|
      row[:upload_failed_to] |= [evt.payload.destination]
    end

    evolve Expense::ExpenseUploadDeleted do |row, evt|
      row[:uploaded_to] -= [evt.payload.destination]
      row[:upload_failed_to] -= [evt.payload.destination]
    end

    sync do |context:, **|
      next unless context[:created_at]

      expense_id = context[:expense_id]
      # FTS5 tables have no upsert: the old entry goes, the new one in.
      index = db[:expenses_search]
      index.where(expense_id:).delete
      # Discarded: the row goes too, and nothing comes back (it's final).
      next db[:expenses].where(expense_id:).delete if context[:machine].include?('discarded')

      row = context.slice(*COLUMNS).merge(JSON_COLUMNS.to_h { [it, JSON.generate(context[it])] })
      db[:expenses].insert_conflict(target: :expense_id, update: row).insert(row.merge(expense_id:))
      index.insert(expense_id:, body: ExpenseList.search_body(context))
    end

    # What a row is found by, a line each.
    def self.search_body(row)
      category = row[:category] && Expenses.category_label(row[:category])
      [row[:description], row[:vendor], category].compact.join("\n")
    end
  end
end
