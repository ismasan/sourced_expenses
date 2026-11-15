# frozen_string_literal: true

require 'rack/test'

RSpec.describe 'Uploading a document' do
  include Rack::Test::Methods

  def app = App

  let(:store) { Sidereal.config['sourced.store'] }
  let(:file_store) { Sidereal.config['file_store'] }
  let(:pdf) { "%PDF-1.4 receipt #{SecureRandom.hex}" }

  def upload(content, filename: 'receipt.pdf', type: 'application/pdf')
    tmp = Tempfile.new(['upload', File.extname(filename)])
    tmp.binmode
    tmp.write(content)
    tmp.rewind
    post '/commands', {
      command: {
        type: 'web.upload_file', _cid: 'web_upload_file-cmd',
        payload: { file: Rack::Test::UploadedFile.new(tmp.path, type, original_filename: filename) }
      }
    }, 'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'
  end

  def uploaded_documents
    store.read_all(limit: 1000).to_a.select { it.is_a?(Expenses::Expense::UploadDocument) }
  end

  it 'stores the file and dispatches UploadDocument with its id' do
    expect { upload(pdf) }.to change { uploaded_documents.size }.by(1)

    expect(last_response.status).to eq(200)
    command = uploaded_documents.last
    file_id = Digest::MD5.hexdigest(pdf)
    expect(command.payload.to_h).to include(filename: 'receipt.pdf', content_type: 'application/pdf',
                                            file_ref: file_id, filing_country: 'NL')
    expect(File.binread(file_store.read(file_id).path)).to eq(pdf)
    expect(last_response.body).to include("/submissions/#{command.payload.expense_id}'")
  end

  it 'refuses a file type it cannot scan' do
    expect { upload('hi', filename: 'notes.txt', type: 'text/plain') }.not_to(change { uploaded_documents.size })

    expect(last_response.body).to include('web_upload_file-cmd-file-errors', 'Upload a PDF or a photo')
  end

  it 'refuses a file over the size limit' do
    expect { upload('x' * (Commands::MAX_UPLOAD_BYTES + 1)) }.not_to(change { uploaded_documents.size })

    expect(last_response.body).to include('web_upload_file-cmd-file-errors', 'That file is over 20 MB')
  end

  it 'refuses a post with no file' do
    expect do
      post '/commands', { command: { type: 'web.upload_file', _cid: 'web_upload_file-cmd', payload: { file: { x: 'y' } } } },
           'HTTP_DATASTAR_REQUEST' => 'true', 'HTTP_ACCEPT' => 'text/event-stream'
    end.not_to(change { uploaded_documents.size })

    # The form can't send this, so no message of its own: the type's, on the file field.
    expect(last_response.body).to include('web_upload_file-cmd-file-errors', 'Must be a Tempfile')
  end
end
