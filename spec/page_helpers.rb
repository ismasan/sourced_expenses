# frozen_string_literal: true

# A document and its expense, for the page specs: the store's own, as the
# app reads it. +document+ histories are Document commands, decided; the
# expense's are Expense commands, the first a DraftExpenseFromDocument (#drafted, the
# one a scan of +scan+ drafts).
module PageHelpers
  D = Documents::Document
  E = Expenses::Expense
  S = Documents::Document::Scanning

  def self.included(group)
    group.let(:store) { Sidereal.config['sourced.store'] }
    group.let(:file_store) { Sidereal.config['file_store'] }
    group.let(:document_id) { SecureRandom.hex(16) }
    group.let(:jpeg) do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'r.jpg')
        system('magick', '-size', '300x400', 'xc:white', path, exception: true)
        File.open(path, 'rb') { file_store.put('lunch.jpg', it) }
      end
    end
    group.let(:extraction) do
      { document_type: 'invoice', description: 'Café Central - Lunch', total_amount: 24.2, net_amount: 20.0,
        tax_amount: 4.2, tax_description: 'BTW 21%', currency: 'EUR', date_as_printed: '9 Aug 2026', date: '2026-08-09',
        vendor_name: 'Café Central', confidence: 'high', supplier_country_code: 'NL', reverse_charge: false }
    end
    group.let(:upload) do
      dcmd(D::UploadDocument, filename: 'lunch.jpg', content_type: 'image/jpeg', file_ref: jpeg, filing_country: 'NL',
                              reference_date: Date.new(2026, 8, 11))
    end
    group.let(:start) { dcmd(D::StartScan) }
    group.let(:scan) do
      [upload, start, dcmd(S::CompletePreparation, processed_file_ref: jpeg), dcmd(S::CompleteExtraction, **extraction),
       dcmd(S::CompleteCleanup, description: 'Café Central — Lunch', tax_description: 'BTW 21%')]
    end
  end

  def dcmd(klass, **payload) = klass.new(payload: { document_id:, **payload })

  # The document after +commands+, in the store.
  def document!(*commands)
    decided(D, { document_id: }, *commands).tap { store.append(it) }
  end

  # The DraftExpenseFromDocument the document drafts once +commands+ (a scan) are done.
  def drafted(*commands)
    doc = D.new(document_id:).tap { it.evolve(decided(D, { document_id: }, *commands)) }.context
    E::DraftExpenseFromDocument.new(payload: doc.prefill)
  end

  # The expense +expense_id+ after +commands+, in the store.
  def expense!(expense_id, *commands)
    decided(E, { expense_id: }, *commands).tap { store.append(it) }
  end
end
