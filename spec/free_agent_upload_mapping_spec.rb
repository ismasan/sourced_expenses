# frozen_string_literal: true

RSpec.describe Integrations::FreeAgent::UploadMapping do
  let(:travel_url) { 'https://api.freeagent.com/v2/categories/365' }
  let(:materials_url) { 'https://api.freeagent.com/v2/categories/366' }
  let(:user) { 'https://api.freeagent.com/v2/users/1' }
  let(:categories) do
    {
      travel_url => Integrations::FreeAgent::Client::Category.new(url: travel_url, nominal_code: '365', description: 'Travel'),
      materials_url => Integrations::FreeAgent::Client::Category.new(url: materials_url, nominal_code: '366', description: 'Materials')
    }
  end

  # What it reads of an Expenses::ExpenseState.
  let(:filed_expense) { Struct.new(:filed, :category, :vat_treatment, keyword_init: true) }

  def doc(treatment: 'domestic', category: 'travel', **filed)
    filed_expense.new(category:, vat_treatment: treatment,
            filed: { description: 'Train to Leeds', net_price_cents: 2000, tax_amount_cents: 400, currency: 'GBP',
                     incurred_on: Date.new(2026, 11, 20), payment_reference: nil, **filed })
  end

  def attributes(doc = self.doc, company_currency: 'GBP')
    described_class.attributes(doc, user:, categories:, company_currency:)
  end

  def refused(doc, **options) = expect { attributes(doc, **options) }.to raise_error(described_class::Refused)

  it 'books domestic VAT at the standard rate its figures make, paid out' do
    expect(attributes).to eq(user:, category: travel_url, dated_on: '2026-11-20', currency: 'GBP',
                             description: 'Train to Leeds', gross_value: '-24.00', ec_status: 'UK/Non-EC',
                             sales_tax_rate: '20.0')
    expect(attributes(doc(tax_amount_cents: 100))).to include(sales_tax_rate: '5.0', gross_value: '-21.00')
    expect(attributes(doc(net_price_cents: 833, tax_amount_cents: 167))).to include(sales_tax_rate: '20.0', gross_value: '-10.00')
    expect(attributes(doc(tax_amount_cents: 0))).to include(sales_tax_rate: '0.0')
  end

  it 'books the other treatments as FreeAgent has them' do
    expect(attributes(doc(treatment: 'reverse_charge', tax_amount_cents: 0))).to include(ec_status: 'Reverse Charge')
    expect(attributes(doc(treatment: 'reverse_charge', incurred_on: Date.new(2020, 6, 1)))).to include(ec_status: 'EC Services')
    expect(attributes(doc(treatment: 'no_vat'))).to include(ec_status: 'UK/Non-EC', sales_tax_rate: '0.0')
    expect(attributes(doc(treatment: 'foreign_vat', currency: 'EUR')))
      .to include(ec_status: 'UK/Non-EC', sales_tax_status: 'OUT_OF_SCOPE', currency: 'EUR')
  end

  it 'finds a category FreeAgent named, one of its own included' do
    expect(attributes(doc(category: 'materials'))).to include(category: materials_url)
  end

  it 'refuses what it can’t book right, saying why' do
    expect { attributes(doc(category: 'computer_software')) }
      .to raise_error(described_class::Refused, /No category on FreeAgent is “Computer Software”/)
    refused(doc(treatment: 'import'))
    refused(doc(treatment: nil))
    refused(doc(tax_amount_cents: 300)) # 15%
    refused(doc(tax_amount_cents: 405)) # nearly 20%: FreeAgent would book 4.01
    refused(doc(net_price_cents: 0, tax_amount_cents: 100))
    refused(doc(currency: 'EUR'))
    refused(doc, company_currency: nil)
    refused(filed_expense.new(filed: nil, category: 'travel', vat_treatment: 'domestic'))
  end

  # FreeAgent's side is assumed: the VAT worked out from the gross and the
  # rate, as it books it.
  it 'comes back from FreeAgent as the same figures' do
    sent = attributes(doc(payment_reference: 'R-1'))
    gross = BigDecimal(sent[:gross_value])
    rate = BigDecimal(sent[:sales_tax_rate])
    # As FreeAgent answers with it: the VAT worked out from the rate.
    back = sent.transform_keys(&:to_s).merge('url' => 'https://api.freeagent.com/v2/expenses/9', 'receipt_reference' => 'R-1',
                                             'sales_tax_value' => (gross * rate / (100 + rate)).round(2).to_s('F'))
    payload = Integrations::FreeAgent::ExpenseMapping.payload(back, categories:, filing_country: 'GB')

    expect(payload).to include(net_price_cents: 2000, tax_amount_cents: 400, currency: 'GBP', incurred_on: Date.new(2026, 11, 20),
                               category: 'travel', vat_treatment: 'domestic', description: 'Train to Leeds',
                               payment_reference: 'R-1')
  end

  describe '.attachment' do
    let(:file_store) { Sidereal.config['file_store'] }
    let(:document) { Struct.new(:filename, :content_type, :file_ref, :processed_file_ref, keyword_init: true) }

    def attachment(filename, content_type, bytes, processed: nil)
      file_ref = file_store.put(filename, bytes)
      processed_file_ref = processed && file_store.put('prepared.jpg', processed)
      described_class.attachment(document.new(filename:, content_type:, file_ref:, processed_file_ref:), file_store:)
    end

    it 'sends a PDF as it is, as FreeAgent names it' do
      expect(attachment('receipt.pdf', 'application/pdf', '%PDF-1.4 receipt'))
        .to eq(data: Base64.strict_encode64('%PDF-1.4 receipt'), file_name: 'receipt.pdf', content_type: 'application/x-pdf')
    end

    it 'sends the JPEG its scan made of a photo FreeAgent doesn’t take' do
      sent = attachment('lunch.webp', 'image/webp', 'RIFF webp', processed: 'JPEG bytes')
      expect(sent).to eq(data: Base64.strict_encode64('JPEG bytes'), file_name: 'lunch.jpg', content_type: 'image/jpeg')
    end

    it 'makes a JPEG of one its scan left as it was' do
      png = Dir.mktmpdir do |dir|
        system('magick', '-size', '4x4', 'xc:red', "webp:#{dir}/x.webp", exception: true)
        File.binread("#{dir}/x.webp")
      end
      sent = attachment('lunch.webp', 'image/webp', png)
      expect(sent).to include(file_name: 'lunch.jpg', content_type: 'image/jpeg')
      expect(Base64.strict_decode64(sent[:data])).to start_with("\xFF\xD8".b)
    end

    it 'refuses a PDF over 5 MB' do
      expect { attachment('big.pdf', 'application/pdf', 'x' * 5_000_001) }
        .to raise_error(described_class::NoAttachment, /over 5 MB/)
    end
  end
end
