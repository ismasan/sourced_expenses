# frozen_string_literal: true

RSpec.describe Integrations::FreeAgent::ExpenseMapping do
  let(:meals_url) { 'https://api.freeagent.com/v2/categories/285' }
  let(:other_url) { 'https://api.freeagent.com/v2/categories/999' }
  let(:categories) do
    {
      meals_url => Integrations::FreeAgent::Client::Category.new(url: meals_url, nominal_code: '285', description: 'Accommodation and Meals'),
      other_url => Integrations::FreeAgent::Client::Category.new(url: other_url, nominal_code: '999', description: 'Widgets For Sale')
    }
  end

  # A FreeAgent expense, as its API answers.
  def expense(**overrides)
    { 'url' => 'https://api.freeagent.com/v2/expenses/123', 'category' => meals_url, 'dated_on' => '2026-11-18',
      'currency' => 'gbp', 'gross_value' => '-24.0', 'sales_tax_value' => '-4.0', 'sales_tax_rate' => '20.0',
      'ec_status' => 'UK/Non-EC', 'description' => 'Lunch with a client', 'receipt_reference' => 'R-9',
      'user' => 'https://api.freeagent.com/v2/users/42', 'updated_at' => '2026-11-20T10:00:00Z',
      **overrides.transform_keys(&:to_s) }
  end

  def payload(**overrides) = described_class.payload(expense(**overrides), categories:, filing_country: 'GB')

  it 'maps an expense to ImportExpense’s payload, its sign flipped into cents' do
    expect(payload).to eq(
      expense_id: 'freeagent-123', source: 'freeagent', external_id: '123', external_url: nil, filing_country: 'GB',
      description: 'Lunch with a client', net_price_cents: 2000, tax_amount_cents: 400, tax_description: 'VAT 20%',
      currency: 'GBP', incurred_on: Date.new(2026, 11, 18), reverse_charge: false, payment_reference: 'R-9',
      category: 'accommodation_and_meals', source_category: 'Accommodation and Meals', vat_treatment: 'domestic'
    )
  end

  it 'links to its page on the company’s FreeAgent site, when it knows the site and the claimant' do
    web_url = 'https://example.freeagent.com'
    expect(described_class.payload(expense, categories:, filing_country: 'GB', web_url:)[:external_url])
      .to eq('https://example.freeagent.com/users/42/expenses/123/edit')
    expect(described_class.payload(expense(user: nil), categories:, filing_country: 'GB', web_url:)[:external_url]).to be_nil
    expect(payload[:external_url]).to be_nil
  end

  it 'builds a valid ImportExpense' do
    expect(Expenses::Expense::ImportExpense.new(payload: payload)).to be_valid
  end

  it 'makes a refund due from the claimant a negative cost' do
    expect(payload(gross_value: '12.0', sales_tax_value: '2.0')).to include(net_price_cents: -1000, tax_amount_cents: -200)
  end

  it 'adds decimal amounts exactly' do
    expect(payload(gross_value: '-0.3', sales_tax_value: '-0.1')).to include(net_price_cents: 20, tax_amount_cents: 10)
    expect(payload(gross_value: '-1234.57', sales_tax_value: '-205.76'))
      .to include(net_price_cents: 102_881, tax_amount_cents: 20_576)
  end

  it 'takes no VAT as zero' do
    expect(payload(sales_tax_value: nil, sales_tax_rate: nil))
      .to include(net_price_cents: 2400, tax_amount_cents: 0, tax_description: nil, vat_treatment: 'no_vat')
  end

  it 'describes the VAT rate, and none for a zero rate' do
    expect(payload(sales_tax_rate: '5.0')[:tax_description]).to eq('VAT 5%')
    expect(payload(sales_tax_rate: '12.5')[:tax_description]).to eq('VAT 12.5%')
    expect(payload(sales_tax_rate: '0.0', sales_tax_value: '0.0')[:tax_description]).to be_nil
  end

  it 'falls back to the category’s name for a blank description, and none without a reference' do
    expect(payload(description: '  ', receipt_reference: '')).to include(description: 'Accommodation and Meals',
                                                                           payment_reference: nil)
  end

  describe 'the VAT treatment' do
    it 'is reverse charged for EC goods and services and the reverse charge' do
      ['Reverse Charge', 'EC Goods', 'EC Services'].each do |status|
        expect(payload(ec_status: status)).to include(vat_treatment: 'reverse_charge', reverse_charge: true), status
      end
    end

    it 'is no VAT when exempt, out of scope, or nothing was charged' do
      expect(payload(sales_tax_status: 'EXEMPT')[:vat_treatment]).to eq('no_vat')
      expect(payload(sales_tax_status: 'OUT_OF_SCOPE')[:vat_treatment]).to eq('no_vat')
      expect(payload(sales_tax_value: '0.0')[:vat_treatment]).to eq('no_vat')
    end

    it 'is domestic otherwise' do
      expect(payload(sales_tax_status: 'TAXABLE')).to include(vat_treatment: 'domestic', reverse_charge: false)
    end
  end

  describe 'the category' do
    it 'is ours where the names match, whatever their case or punctuation' do
      expect(described_class.ours('Accommodation and Meals')).to eq('accommodation_and_meals')
      expect(described_class.ours('Bank/Finance Charges')).to eq('bank_finance_charges')
      expect(described_class.ours('ACCOMMODATION & MEALS')).to eq('accommodation_and_meals')
      expect(described_class.normalize('Bank/Finance Charges')).to eq(described_class.normalize('Bank and Finance charges'))
    end

    it 'is its own for a name that is none of the baseline’s, keyed from its name' do
      expect(payload(category: other_url)).to include(category: 'widgets_for_sale', source_category: 'Widgets For Sale')
      expect(Expenses::Expense::ImportExpense.new(payload: payload(category: other_url))).to be_valid
    end

    it 'is none for a category it doesn’t know' do
      expect(payload(category: 'https://api.freeagent.com/v2/categories/1', description: nil))
        .to include(category: nil, source_category: nil, description: nil)
    end
  end

  it 'skips mileage claims, and anything without an amount' do
    expect(payload(category: 'Mileage')).to be_nil
    expect(payload(gross_value: nil)).to be_nil
  end
end
