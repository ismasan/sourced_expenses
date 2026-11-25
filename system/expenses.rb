# frozen_string_literal: true

# Expense tracking, from scanned receipts and invoices or by hand: a photo or
# PDF goes in, several small LLM calls read it and draft an expense, a person
# reviews the prefilled form and files the expense, and a plain rule (not the
# model) infers its VAT treatment. The model suggests its category
# (Categorizer); a person has the last word. An expense needn't come from a
# document: a person can draft one by hand, and other sources can too.
# After https://gist.github.com/julik/405662cc3106fe73ae2e46073f483b62
#
#   Document                one per uploaded file: reads it, drafts its expense
#   └ Document::Scanning    (part: the OCR pipeline, one LLM call per state)
#   Expense                 one per expense, however drafted: review, file
#
# The machines are the spec: every LLM call is a state waiting for its
# worker to report back (Complete…/Fail…), and every decision between calls
# is code, in DocumentState and ExpenseState. Nothing here calls a model.
module Expenses
  # How an expense's VAT is accounted for. See ExpenseState.infer_vat_treatment.
  #
  #   domestic        the filing country's own VAT; reclaimable
  #   import          import VAT on goods; reclaimable. Only ever chosen by a person
  #   reverse_charge  you account for the VAT and reclaim the same amount
  #   foreign_vat     another country's VAT; never reclaimable on this return
  #   no_vat          exempt, outside scope, or not a tax
  VAT_TREATMENTS = %w[domestic import reverse_charge foreign_vat no_vat].freeze

  # The accounting category an expense is booked under, and what goes in
  # it: the descriptions are what Expenses::CategoryJudge shows the model.
  # Modelled on the default expense categories of UK bookkeeping apps (FreeAgent's
  # admin expenses, Xero's chart of accounts), which split costs the way a
  # small company's tax return does. A model suggests one (Expenses::Categorizer);
  # a person's choice is final.
  CATEGORIES = {
    'accommodation_and_meals' => ['Accommodation and meals', 'Hotels, lodging, and meals while travelling away from home on business'],
    'accountancy_and_legal' => ['Accountancy and legal', 'Accountants, bookkeepers, solicitors, company formation and filing fees'],
    'advertising' => ['Advertising and marketing', 'Ads, sponsorships, promotional material, marketing services'],
    'bank_charges' => ['Bank and finance charges', 'Bank fees, card and payment processing fees, currency conversion charges, interest'],
    'business_entertaining' => ['Business entertaining', 'Meals, drinks, gifts or events for clients, prospects or suppliers'],
    'cleaning' => ['Cleaning', 'Cleaning services and supplies for business premises'],
    'clothing' => ['Clothing and uniforms', 'Uniforms, protective clothing and workwear'],
    'computer_equipment' => ['Computer equipment', 'Computers, laptops, phones, tablets, monitors, peripherals and other hardware'],
    'consultancy' => ['Consultancy and subcontractors', 'Freelancers, contractors and consultants doing work for the business'],
    'donations' => ['Charitable donations', 'Donations to charities'],
    'equipment_hire' => ['Equipment hire', 'Renting or leasing tools, machinery or other equipment'],
    'insurance' => ['Insurance', 'Business, professional indemnity, liability and contents insurance'],
    'motor_expenses' => ['Motor expenses', 'Fuel, parking, tolls, congestion charges, vehicle servicing, repairs and road tax'],
    'office_costs' => ['Office costs', 'Stationery, office supplies, small office furniture and sundries'],
    'postage' => ['Postage and delivery', 'Stamps, couriers, shipping and delivery charges'],
    'printing' => ['Printing', 'Printing, copying and business cards'],
    'rent_and_rates' => ['Rent and rates', 'Office or workspace rent, co-working memberships, business rates'],
    'repairs' => ['Repairs and maintenance', 'Repairs and upkeep of premises and equipment'],
    'software' => ['Software and web services', 'Software licences, SaaS and cloud subscriptions, web hosting, domains, app store purchases'],
    'staff_entertaining' => ['Staff entertaining', 'Parties, meals and events for employees only'],
    'subscriptions' => ['Subscriptions and memberships', 'Professional body memberships, trade associations, newspapers, magazines and other publications'],
    'telephone_and_internet' => ['Telephone and internet', 'Phone lines, mobile plans, broadband and internet access'],
    'training' => ['Training', 'Courses, conferences, workshops, books and learning materials'],
    'travel' => ['Travel', 'Flights, trains, buses, taxis, ride-hailing, car hire and public transport'],
    'utilities' => ['Light, heat and power', 'Electricity, gas, water and heating for business premises'],
    'general' => ['General expenses', 'Business costs that fit none of the other categories']
  }.freeze

  # A category's name for people.
  def self.category_label(key) = CATEGORIES.dig(key, 0) || key

  def self.machines = [Document, Expense]
end
