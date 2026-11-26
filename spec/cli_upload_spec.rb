# frozen_string_literal: true

require 'sidereal/cli'
require_relative '../cli/expenses'

RSpec.describe CLI::Expenses::Upload do
  let(:store) { Sidereal.config['sourced.store'] }
  let(:file_store) { Sidereal.config['file_store'] }
  let(:dir) { Dir.mktmpdir }
  let(:out) { StringIO.new }

  after { FileUtils.remove_entry(dir) }

  # The app is built already, by spec_helper.
  before { allow(Sidereal::CLI).to receive(:boot_app!) }

  def file(name, content = "%PDF-1.4 receipt #{SecureRandom.hex}")
    File.join(dir, name).tap { File.binwrite(it, content) }
  end

  def run(*arguments) = described_class.new(arguments, output: out).call

  def uploaded_documents
    store.read_all(limit: 1000).to_a.select { it.is_a?(Documents::Document::UploadDocument) }
  end

  it 'stores each file and dispatches its UploadDocument, saying where to watch it scan' do
    pdf = file('lunch.pdf')
    photo = file('Taxi.JPG', 'jpeg bytes')

    expect { run(pdf, photo) }.to change { uploaded_documents.size }.by(2)

    lunch, taxi = uploaded_documents.last(2).map(&:payload)
    digest = Digest::MD5.file(pdf).hexdigest
    expect(lunch.to_h).to include(document_id: digest, filename: 'lunch.pdf', content_type: 'application/pdf', file_ref: digest,
                                  filing_country: 'NL', reference_date: Date.today)
    expect(taxi.to_h).to include(filename: 'Taxi.JPG', content_type: 'image/jpeg')
    expect(File.binread(file_store.read(lunch.file_ref).path)).to eq(File.binread(pdf))
    expect(out.string).to include("Uploaded #{pdf}", "http://localhost:9292/documents/#{lunch.document_id}")
  end

  it 'says so for a file uploaded before, and dispatches nothing' do
    pdf = file('lunch.pdf')
    run(pdf)
    document_id = uploaded_documents.last.payload.document_id
    copy = File.join(dir, 'copy.pdf').tap { FileUtils.cp(pdf, it) }

    expect { run(copy) }.not_to(change { uploaded_documents.size })
    expect(out.string).to include("Already uploaded #{copy}", "/documents/#{document_id}")
  end

  it 'reads dates against the reference date given' do
    run('--reference-date', '2025-10-24', file('lunch.pdf'))

    expect(uploaded_documents.last.payload.reference_date).to eq(Date.new(2025, 10, 24))
  end

  it 'skips what the form would refuse, uploads the rest, and fails' do
    notes = file('notes.txt', 'hi')
    big = file('big.pdf', 'x' * (Documents::Upload::MAX_BYTES + 1))
    missing = File.join(dir, 'missing.pdf')

    expect { run(notes, big, missing, file('lunch.pdf')) }
      .to raise_error(Sidereal::CLI::Error, '3 of 4 not uploaded')
      .and change { uploaded_documents.size }.by(1)
    expect(out.string).to include("Skipped #{notes}: Upload a PDF or a photo", "Skipped #{big}: That file is over 20 MB",
                                  "Skipped #{missing}: No such file")
  end

  it 'refuses a reference date that is not one, before uploading anything' do
    before = uploaded_documents.size

    expect { run('--reference-date', '24/10/2025', file('lunch.pdf')) }.to raise_error(Sidereal::CLI::Error, /isn't a date/)
    expect(uploaded_documents.size).to eq(before)
  end

  it 'asks for a file' do
    expect { run }.to raise_error(Sidereal::CLI::Error, /Name a file/)
  end
end
