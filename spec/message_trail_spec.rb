# frozen_string_literal: true

require 'rack/test'

RSpec.describe UI::Components::MessageTrail do
  include Rack::Test::Methods

  def app = App

  let(:store) { Sidereal.config['sourced.store'] }
  let(:db) { Sidereal.config['db'] }
  let(:expense_id) { SecureRandom.hex(16) }
  let(:document_id) { SecureRandom.hex(16) }

  around do |example|
    db.transaction(rollback: :always, auto_savepoint: true) { example.run }
  end

  # A document's upload, the expense it drafted, and that expense's upload
  # recorded by FreeAgent's uploader: one workflow across streams. And an
  # unrelated message, in a correlation of its own.
  let!(:upload) do
    Documents::Document::UploadDocument.new(payload: { document_id:, filename: 'r.pdf', content_type: 'application/pdf',
                                                       file_ref: document_id, filing_country: 'GB' })
  end
  let!(:uploaded) do
    upload.correlate(Documents::Document::DocumentUploaded.new(payload: { document_id:, filename: 'r.pdf', content_type: 'application/pdf',
                                                                          file_ref: document_id, filing_country: 'GB' }))
  end
  let!(:drafted) do
    uploaded.correlate(Expenses::Expense::DraftExpenseFromDocument.new(payload: { expense_id:, document_id:, filing_country: 'GB' }))
  end
  let!(:recorded) do
    drafted.correlate(Expenses::Expense::RecordUpload.new(payload: { expense_id:, destination: 'freeagent', external_id: '9' }))
           .with_metadata(producer: 'freeagent.upload')
  end
  let!(:other) { Expenses::Expense::DiscardExpense.new(payload: { expense_id: SecureRandom.hex(16) }) }

  before { store.append([upload, uploaded, drafted, recorded, other]) }

  it 'reads every message in its correlation, in order, whichever it’s asked about' do
    entries = described_class.entries(drafted.id)

    expect(entries.map(&:id)).to eq([upload, uploaded, drafted, recorded].map(&:id))
    expect(entries.map(&:kind)).to eq(%i[command data command command])
    expect(entries.last).to have_attributes(producer: 'freeagent.upload', payload: include('external_id' => '9'))
    expect(entries.first.created_at).to be_a(Time)
    expect(described_class.entries(SecureRandom.uuid)).to eq([])
  end

  it 'puts each message under the one that caused it' do
    roots = described_class.tree(described_class.entries(upload.id))

    expect(roots.map { it.entry.id }).to eq([upload.id])
    chain = [roots.first]
    chain << chain.last.children.first while chain.last.children.any?
    expect(chain.map { it.entry.id }).to eq([upload, uploaded, drafted, recorded].map(&:id))
  end

  it 'still shows a message whose type is no longer known' do
    table = store.installer.messages_table
    store.db[table].where(message_id: uploaded.id).update(message_type: 'documents.long_gone')

    entry = described_class.entries(upload.id).find { it.id == uploaded.id }
    expect(entry).to have_attributes(type: 'documents.long_gone', kind: :unknown)
  end

  describe 'the dialog' do
    def trail(id, at: nil)
      get "/messages/#{id}/trail", { at: }.compact, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'
      last_response.body
    end

    it 'opens over the page, marking the message clicked and linking to each record and the step' do
      body = trail(drafted.id, at: "/documents/#{document_id}/at/2")

      expect(body).to include('datastar-patch-elements', 'mode replace', 'dialog id="message-trail"', 'el.showModal()',
                              '4 messages, 2 streams', 'documents.upload_document', 'expenses.record_upload',
                              'by freeagent.upload', "href=\"/expenses/#{expense_id}\"",
                              "href=\"/documents/#{document_id}\"", 'Page at this step',
                              "@get('/documents/#{document_id}/at/2')")
      expect(body.scan('is-selected').size).to eq(1)
      expect(body).not_to include('expenses.discard_expense')
    end

    it 'leaves out a step link that isn’t one of the app’s paths' do
      expect(trail(drafted.id, at: 'https://elsewhere.test/x')).not_to include('Page at this step')
    end

    it 'sends anything but a Datastar request to the step' do
      get "/messages/#{drafted.id}/trail", at: "/documents/#{document_id}/at/2"

      expect(last_response.status).to eq(303)
      expect(last_response.location).to end_with("/documents/#{document_id}/at/2")
    end
  end

  it 'opens from a message in a record’s history' do
    get "/documents/#{document_id}"

    expect(last_response.body).to include('id="message-trail"', "@get('/messages/#{upload.id}/trail?at=")
  end
end
