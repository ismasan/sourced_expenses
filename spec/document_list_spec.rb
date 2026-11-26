# frozen_string_literal: true

require 'sourced/testing/rspec'

module Documents
  RSpec.describe DocumentList do
    include Sourced::Testing::RSpec

    let(:db) { Sidereal.config['db'] }
    let(:document_id) { SecureRandom.hex(16) }
    S = Document::Scanning unless defined?(S)

    def cmd(klass, **payload) = klass.new(payload: { document_id:, **payload })
    def row = DocumentList.page(db, per_page: 1000)[0].find { it.document_id == document_id }
    def after(*commands, given:) = decided(Document, { document_id: }, *commands, given:)

    # Projects each history in turn, as separate batches would.
    def project(*histories)
      histories.each do |history|
        history.reduce(with_reactor(DocumentList, document_id:)) { |r, m| r.given(m) }.then! { nil }
      end
    end

    let(:uploaded) do
      decided(Document, { document_id: },
              cmd(Document::UploadDocument, filename: 'lunch.pdf', content_type: 'application/pdf', file_ref: 'f1',
                                            filing_country: 'NL'),
              cmd(Document::StartScan))
    end

    let(:extraction) do
      { document_type: 'invoice', description: 'Café - Lunch', total_amount: 24.2, net_amount: 20.0, tax_amount: 4.2,
        currency: 'EUR', date_as_printed: '9 Aug 2026', date: '2026-08-09', vendor_name: 'Café', confidence: 'high' }
    end

    it 'deletes every row when its group is reset, to build them again' do
      db.transaction(rollback: :always, auto_savepoint: true) do
        project(uploaded)
        expect(row).not_to be_nil

        DocumentList.on_reset

        expect(db[:documents].count).to eq(0)
      end
    end

    it 'lists an upload at the step its scan is at' do
      project(uploaded)

      expect(row).to have_attributes(filename: 'lunch.pdf', content_type: 'application/pdf', file_ref: 'f1',
                                     machine: %w[scanning scanning.preparing])
    end

    it 'follows the scan across batches, with what it read, until read' do
      extracting = after(cmd(S::CompletePreparation, processed_file_ref: 'f1'), given: uploaded)
      read = after(cmd(S::CompleteExtraction, **extraction), given: extracting)
      project(uploaded, extracting - uploaded, read - extracting)

      expect(row).to have_attributes(machine: %w[scanning scanning.cleaning], description: 'Café - Lunch', vendor: 'Café',
                                     total_cents: 2420, currency: 'EUR', incurred_on: Date.new(2026, 8, 9))

      scanned = after(cmd(S::CompleteCleanup, description: 'Café Central - Lunch', tax_description: nil), given: read)
      project(scanned - read)
      expect(row).to have_attributes(machine: ['scanned'], description: 'Café Central - Lunch')
    end

    it 'keeps why a scan failed' do
      failed = after(cmd(S::FailPreparation, reason: 'Too big'), given: uploaded)
      project(failed)

      expect(row).to have_attributes(machine: ['scan_failed'], failure: 'Too big')
      expect(row.in?('scan_failed')).to be(true)
    end

    it 'keeps why it is not a receipt' do
      rejected = after(cmd(S::CompletePreparation, processed_file_ref: 'f1'),
                       cmd(S::CompleteExtraction, **extraction, total_amount: nil),
                       cmd(S::CompleteVerification, is_invoice_or_receipt: false, explanation: 'A cat photo'),
                       given: uploaded)
      project(rejected)

      expect(row).to have_attributes(machine: ['rejected'], rejection: 'A cat photo')
    end

    it 'starts from nothing on a rescan' do
      failed = after(cmd(S::CompletePreparation, processed_file_ref: 'f1'), cmd(S::CompleteExtraction, **extraction),
                     cmd(S::FailCleanup, reason: 'x'), given: uploaded)
      rescanned = after(cmd(Document::Rescan), given: failed)
      project(failed, rescanned - failed)

      expect(row).to have_attributes(machine: ['queued'], description: nil, total_cents: nil, failure: nil, rejection: nil)
    end

    it 'removes a discarded document' do
      project(uploaded)
      discarded = after(cmd(Document::DiscardDocument), given: uploaded)
      project(discarded - uploaded)

      expect(row).to be_nil
      expect(db[:documents].where(document_id:).count).to eq(0)
    end

    describe '.page' do
      around do |example|
        db.transaction(rollback: :always, auto_savepoint: true) do
          db[:documents].delete
          example.run
        end
      end

      def document(name, *paths, at: Time.now)
        db[:documents].insert(document_id: name, filename: "#{name}.pdf", machine: JSON.generate(paths), uploaded_at: at,
                              updated_at: at)
      end

      it 'pages through the rows in any of the states, newest first, none yet counting as being read' do
        document('storing', at: Time.now - 50)
        document('queued', 'queued', at: Time.now - 40)
        document('reading', 'scanning', 'scanning.extracting', at: Time.now - 30)
        document('icon', 'rejected', at: Time.now - 20)
        document('broken', 'scan_failed', at: Time.now - 10)
        document('read', 'scanned')
        document('by-hand', 'entered_by_hand')

        rows, total = DocumentList.page(db, states: %w[scanning])
        expect([rows.map(&:document_id), total]).to eq([%w[reading queued storing], 3])
        rows, total = DocumentList.page(db, states: DocumentList::NEEDS_YOU, per_page: 1)
        expect([rows.map(&:document_id), total]).to eq([%w[broken], 2])
        expect(DocumentList.page(db)[1]).to eq(7)
      end
    end
  end
end
