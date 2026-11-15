# frozen_string_literal: true

require 'tmpdir'

RSpec.describe FileStore::Disk do
  around do |example|
    Dir.mktmpdir { |root| @root = root; example.run }
  end

  subject(:store) { described_class.new(root: @root) }

  it 'stores a file by the MD5 of its bytes and reads it back' do
    id = store.put('lunch.jpg', 'hello')

    expect(id).to eq(Digest::MD5.hexdigest('hello'))
    file = store.read(id)
    expect(file.filename).to eq('lunch.jpg')
    expect(file.size).to eq(5)
    expect(File.binread(file.path)).to eq('hello')
  end

  it "names the stored file after the upload's extension" do
    expect(File.basename(store.read(store.put('Receipt.PDF', 'a')).path)).to eq('data.pdf')
    expect(File.basename(store.read(store.put('README', 'b')).path)).to eq('data')
    expect(File.basename(store.read(store.put('odd.p d/f', 'c')).path)).to eq('data')
  end

  it 'streams from an IO' do
    id = store.put('lunch.jpg', StringIO.new('hello'))

    expect(File.binread(store.read(id).path)).to eq('hello')
  end

  it 'stores the same bytes once, under the first name' do
    first = store.put('lunch.jpg', 'hello')
    second = store.put('again.jpg', 'hello')

    expect(second).to eq(first)
    expect(store.read(first).filename).to eq('lunch.jpg')
    expect(Dir.glob(File.join(@root, '*/*'))).to eq([File.dirname(store.read(first).path)])
    expect(Dir.children(File.join(@root, 'tmp'))).to be_empty
  end

  it 'keeps the client filename out of the path' do
    id = store.put('../../etc/passwd', 'hello')

    file = store.read(id)
    expect(file.filename).to eq('passwd')
    expect(file.path).to start_with(@root)
  end

  it 'raises NotFound for an unknown or malformed id' do
    expect { store.read('0' * 32) }.to raise_error(FileStore::NotFound)
    expect { store.read('../../etc') }.to raise_error(FileStore::NotFound)
  end
end
