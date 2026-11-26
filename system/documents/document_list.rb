# frozen_string_literal: true

require 'json'

module Documents
  # The read model behind the home page's documents: one row per uploaded
  # document, in the `documents` table, rewritten whenever it moves: being
  # read, read (its expense drafted: ExpenseList has it from then on), or
  # not (rejected, or the scan failed). Where the machine is (its paths)
  # comes from the state events, as ExpenseList's.
  #
  # A discarded document leaves it.
  #
  # Sidereal publishes DocumentList::Projected after every committed batch,
  # which is what the home page reacts to.
  class DocumentList < Sourced::Projector::StateStored
    partition_by document_id: Types::DocumentID

    dep :db

    Row = ::Data.define(:document_id, :filename, :content_type, :file_ref, :machine, :failure, :rejection,
                        :description, :vendor, :total_cents, :currency, :incurred_on, :uploaded_at,
                        :updated_at) do
      def in?(path) = machine.include?(path)
    end

    COLUMNS = %i[filename content_type file_ref machine failure rejection description vendor total_cents
                 currency incurred_on uploaded_at updated_at].freeze

    def self.in_path(path)
      Sequel.lit('EXISTS (SELECT 1 FROM json_each(documents.machine) WHERE value = ?)', path)
    end

    # Where a document is: each a condition on the machine's paths, every
    # row in exactly one. No paths yet (the upload is still being stored)
    # counts as being read, and so does waiting for a scanning slot.
    STATES = {
      'scanning' => Sequel.|(in_path('scanning'), in_path('queued'), { machine: '[]' }),
      'scanned' => in_path('scanned'),
      'entered_by_hand' => in_path('entered_by_hand'),
      'rejected' => in_path('rejected'),
      'scan_failed' => in_path('scan_failed')
    }.freeze

    # The states waiting for a person: read, but not as an expense.
    NEEDS_YOU = %w[rejected scan_failed].freeze

    # One page of the rows in any of +states+ (STATES keys; all, for none),
    # the latest uploads first.
    # @return [Array(Array<Row>, Integer)] the page's rows, and how many there are in all
    def self.page(db, states: [], page: 1, per_page: 25)
      chosen = STATES.values_at(*(STATES.keys & states))
      ds = chosen.empty? ? db[:documents] : db[:documents].where(Sequel.|(*chosen))
      rows = ds.reverse(:uploaded_at).limit(per_page, (page - 1) * per_page).map { row(it) }
      [rows, ds.count]
    end

    def self.row(row) = Row.new(**row.slice(*Row.members), machine: JSON.parse(row[:machine]))

    # The group's offsets were rewound (`bin/sid sourced groups reset
    # documents.document_list`): every row goes, and it builds them again
    # from the start of the store once started.
    def self.on_reset = Sidereal.config['db'][:documents].delete

    D = Document
    S = Document::Scanning

    context { { machine: [] } }

    load_context do |partition|
      row = db[:documents].where(document_id: partition[:document_id]).first
      row&.merge(machine: JSON.parse(row[:machine]))
    end

    D.transition_classes.each do |klass|
      evolve klass do |row, evt|
        row[:document_id] = evt.payload.document_id
        row[:machine] = (row[:machine] - evt.payload.exited) | evt.payload.entered
        row[:updated_at] = evt.created_at
      end
    end

    evolve D::DocumentUploaded do |row, evt|
      row.merge!(evt.payload.to_h.slice(:document_id, :filename, :content_type, :file_ref))
      row[:uploaded_at] = evt.created_at
    end

    # A rescan starts from nothing.
    evolve D::ScanRequested do |row, _evt|
      row.merge!(failure: nil, rejection: nil, description: nil, vendor: nil, total_cents: nil, currency: nil,
                 incurred_on: nil)
    end

    evolve D::StepFailed do |row, evt|
      row[:failure] = evt.payload.reason
    end

    evolve S::DocumentVerified do |row, evt|
      row[:rejection] = evt.payload.explanation unless evt.payload.is_invoice_or_receipt
    end

    evolve S::ExtractionRecorded do |row, evt|
      total = evt.payload.total_amount
      row.merge!(
        description: evt.payload.description,
        vendor: evt.payload.vendor_name,
        total_cents: total && (total * 100).round,
        currency: evt.payload.currency,
        incurred_on: Types.iso_date(evt.payload.date)
      )
    end

    evolve S::DateRechecked do |row, evt|
      row[:incurred_on] = Types.iso_date(evt.payload.corrected_date) if evt.payload.corrected_date
    end

    evolve S::TextCleaned do |row, evt|
      row[:description] = evt.payload.description
    end

    sync do |context:, **|
      next unless context[:filename]

      document_id = context[:document_id]
      # Discarded: the row goes, and nothing comes back (it's final).
      next db[:documents].where(document_id:).delete if context[:machine].include?('discarded')

      row = context.slice(*COLUMNS).merge(machine: JSON.generate(context[:machine]))
      db[:documents].insert_conflict(target: :document_id, update: row).insert(row.merge(document_id:))
    end
  end
end
