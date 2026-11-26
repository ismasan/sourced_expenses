# frozen_string_literal: true

# Expense tracking: an expense is drafted (from a scanned document:
# Documents), entered by hand, or imported from another system
# (Integrations); a person reviews it and files it, and a plain rule (not
# the model) infers its VAT treatment. The model suggests its category
# (Categorizer); a person has the last word.
# After https://gist.github.com/julik/405662cc3106fe73ae2e46073f483b62
#
#   Expense                 one per expense, however it came: review, file
#
# The machine is the spec, and every decision is code, in ExpenseState.
module Expenses
  # How an expense's VAT is accounted for. See ExpenseState.infer_vat_treatment.
  #
  #   domestic        the filing country's own VAT; reclaimable
  #   import          import VAT on goods; reclaimable. Only ever chosen by a person
  #   reverse_charge  you account for the VAT and reclaim the same amount
  #   foreign_vat     another country's VAT; never reclaimable on this return
  #   no_vat          exempt, outside scope, or not a tax
  VAT_TREATMENTS = %w[domestic import reverse_charge foreign_vat no_vat].freeze

  # The baseline of accounting categories an expense is booked under, and
  # what goes in each: the descriptions are what Expenses::CategoryJudge
  # shows the model. FreeAgent's own expense categories, by its names, so
  # an expense uploaded there (Integrations::FreeAgentUpload) finds its
  # category by name, and one imported from there comes back under the same
  # key: each key is its name's (.category_key).
  #
  # Not the only ones: a category is any key (Expense::Category), and every
  # one an expense has had is in Expenses::CategoryList, a source's own
  # among them. The model chooses among these and those
  # (Expenses::Categorizer); a person's choice is final.
  CATEGORIES = {
    'accommodation_and_meals' => ['Accommodation and Meals', 'Hotels, lodging, and meals while travelling away from home on business'],
    'accountancy_fees' => ['Accountancy Fees', 'Accountants and bookkeepers, payroll and tax return services'],
    'legal_and_professional_fees' => ['Legal and Professional Fees', 'Solicitors, other professional advisers, company filing fees'],
    'advertising_and_promotion' => ['Advertising and Promotion', 'Ads, sponsorships, promotional material, marketing services'],
    'bank_finance_charges' => ['Bank/Finance Charges', 'Bank fees, card and payment processing fees, currency conversion charges'],
    'books_and_journals' => ['Books and Journals', 'Books, e-books, newspapers, magazines and other publications'],
    'business_entertaining' => ['Business Entertaining', 'Meals, drinks, gifts or events for clients, prospects or suppliers'],
    'charitable_donations' => ['Charitable Donations', 'Donations to charities'],
    'computer_hardware' => ['Computer Hardware', 'Computers, laptops, tablets, monitors, peripherals and other hardware'],
    'computer_software' => ['Computer Software', 'Software licences, SaaS and cloud subscriptions, app store purchases'],
    'web_hosting' => ['Web Hosting', 'Web hosting, servers and domain names'],
    'other_computer_costs' => ['Other Computer Costs', 'Computer repairs, cables, small accessories and other computer sundries'],
    'consultancy_fees' => ['Consultancy Fees', 'Consultants and freelancers advising or doing work for the business'],
    'subcontractor_costs' => ['Subcontractor Costs', 'Subcontractors doing work the business sells on to its clients'],
    'equipment_hire' => ['Equipment Hire', 'Renting or leasing tools, machinery or other equipment'],
    'office_equipment' => ['Office Equipment', 'Office furniture, desks, chairs, lamps and other office equipment'],
    'insurance' => ['Insurance', 'Business, professional indemnity, liability and contents insurance'],
    'motor_expenses' => ['Motor Expenses', 'Fuel, parking, tolls, congestion charges, vehicle servicing, repairs and road tax'],
    'office_costs' => ['Office Costs', 'Office supplies, cleaning, repairs and sundries for business premises'],
    'stationery' => ['Stationery', 'Paper, pens, notebooks, envelopes and other stationery'],
    'printing' => ['Printing', 'Printing, copying and business cards'],
    'postage' => ['Postage', 'Stamps, couriers, shipping and delivery charges'],
    'rent' => ['Rent', 'Office or workspace rent, co-working memberships, business rates'],
    'use_of_home' => ['Use Of Home', 'A share of home running costs (heating, light, power) for working from home'],
    'subscriptions' => ['Subscriptions', 'Professional body memberships, trade associations and other subscriptions'],
    'internet_and_telephone' => ['Internet & Telephone', 'Broadband, internet access and landlines'],
    'mobile_phone' => ['Mobile Phone', 'Mobile phone plans and handsets'],
    'staff_training' => ['Staff Training', 'Courses, conferences, workshops and learning materials'],
    'staff_entertaining' => ['Staff Entertaining', 'Parties, meals and events for employees only'],
    'travel' => ['Travel', 'Flights, trains, buses, taxis, ride-hailing, car hire and public transport'],
    'sundries' => ['Sundries', 'Business costs that fit none of the other categories, including workwear and protective clothing']
  }.freeze

  # A category's name for people: the baseline's, or else the one it came
  # with (CategoryList), or else its key, made readable.
  def self.category_label(key) = CATEGORIES.dig(key, 0) || CategoryList.label(key) || key.to_s.tr('_', ' ').capitalize

  # The key for a category named +name+: "Use of home" is use_of_home.
  def self.category_key(name) = name.to_s.downcase.gsub('&', ' and ').gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')

  def self.machines = [Expense]
end
