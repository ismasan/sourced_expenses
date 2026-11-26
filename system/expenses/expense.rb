# frozen_string_literal: true

require 'date'

module Expenses
  # One expense, from its first figures to a filed expense. Its events say
  # what the expense is: drafted (tentative figures, a scan's reading, for
  # a person to check), redrafted (new tentative figures: its document read
  # again), entered (a person's own figures), filed. Where it
  # came from is a fact of its own: a document attached to it.
  #
  # Each source starts it with its own command, under an id of its choosing:
  # a scanned document drafts it (DraftExpenseFromDocument, with the
  # document's id: ExpenseDrafted and DocumentAttached), a person enters it
  # (EnterExpense, a UUID: ExpenseEntered), another system's expense is
  # imported (ImportExpense, the source's name and its id there, e.g.
  # freeagent-123: ExpenseImported, then CategoryChosen,
  # VatTreatmentConfirmed and ExpenseFiled: its source's books are trusted,
  # so it's filed as it is there).
  #
  #   initial ─DraftExpenseFromDocument | EnterExpense | ImportExpense─▶ reviewing ─done─▶ reviewed ─SaveExpense─▶ filed ⟲ SaveExpense
  #
  #   reviewing:  category  ─ChooseCategory──────▶ category_confirmed
  #               vat       ─ConfirmVatTreatment─▶ vat_confirmed
  #
  #   filed ─VoidExpense─▶ voided;  reviewing, reviewed ─DiscardExpense─▶ discarded
  #   reviewing, reviewed ⟲ DraftExpenseFromDocument (its attached document read again: a new draft)
  #   initial ─ImportExpense─▶ filed (its source's category and VAT treatment, confirmed),
  #                          or reviewing, for one without them (to choose here)
  #   reviewing, reviewed, filed ⟲ ImportExpense (changed at its source: applied, and filed again once filed)
  #   reviewing, reviewed, filed ⟲ SuggestCategory | FailCategorization | ChooseCategory | ConfirmVatTreatment
  #
  # The model never writes the expense and never decides its tax treatment:
  # a draft prefills a form, and a person files it. Reviewing has two steps,
  # in either order: choosing the category (the model's suggestion, from
  # Expenses::Categorizer, until a person chooses one) and confirming the VAT
  # treatment (the rule's, ExpenseState#suggested_vat_treatment, until a
  # person confirms one). Only once both are done is the expense reviewed,
  # and only a reviewed expense can be filed.
  class Expense < Sourced::Machine
    partition_by expense_id: Types::ExpenseID
    message_prefix 'expenses'

    CurrencyCode = Types::String[/\A[A-Z]{3}\z/]
    CountryCode = Types::String[/\A[A-Z]{2}\z/]

    # The form's fields, which SaveExpense files: all of them optional in a
    # draft, as a scan may read none of them.
    DRAFT = %i[description net_price_cents tax_amount_cents tax_description currency incurred_on
               supplier_country_code reverse_charge payment_reference].freeze

    # ---- States ----

    Reviewing = State(:reviewing)
    CategoryConfirmed = State(:category_confirmed)
    VatConfirmed = State(:vat_confirmed)
    Reviewed = State(:reviewed)
    Filed = State(:filed)
    Discarded = State(:discarded)
    Voided = State(:voided)

    # ---- Commands ----

    # The expense, drafted from what +document_id+ (an uploaded document)
    # read: +filing_country+ is the country of the company whose books it's
    # in, +vendor+ who it's from, if read, and the rest the form to prefill,
    # any of it missing. The first starts the expense and attaches the
    # document; another for the same document, while it's in review,
    # redrafts it (the document read again). The same again changes nothing.
    DraftExpenseFromDocument = Command(:draft_expense_from_document) do
      attribute :expense_id, Types::ExpenseID
      attribute :document_id, Types::DocumentID
      attribute :filing_country, CountryCode
      attribute :vendor, Types::String.nullable.default(nil)
      attribute :description, Types::String.nullable.default(nil)
      attribute :net_price_cents, Types::Integer.nullable.default(nil)
      attribute :tax_amount_cents, Types::Integer.nullable.default(nil)
      attribute :tax_description, Types::String.nullable.default(nil)
      attribute :currency, CurrencyCode.nullable.default(nil)
      attribute :incurred_on, Types::Date.nullable.default(nil)
      attribute :supplier_country_code, CountryCode.nullable.default(nil)
      attribute :reverse_charge, Types::Boolean.nullable.default(nil)
      attribute :payment_reference, Types::String.nullable.default(nil)
    end

    # The expense, entered by a person: the form as SaveExpense takes it.
    # Only starts one: the same again changes nothing, and a correction is
    # the review's SaveExpense.
    EnterExpense = Command(:enter_expense) do
      attribute :expense_id, Types::ExpenseID
      attribute :filing_country, CountryCode
      attribute :description, Types::String.present
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Types::Integer.default(0)
      attribute :tax_description, Types::String.nullable.default(nil)
      attribute :currency, CurrencyCode
      attribute :incurred_on, Date
      attribute :supplier_country_code, CountryCode.nullable.default(nil)
      attribute :reverse_charge, Types::Boolean.default(false)
      attribute :payment_reference, Types::String.nullable.default(nil)
    end

    # The reviewed form. Amounts are integer cents, negative for credit notes.
    SaveExpense = Command(:save_expense) do
      attribute :description, Types::String.present
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Types::Integer.default(0)
      attribute :tax_description, Types::String.nullable
      attribute :currency, CurrencyCode
      attribute :incurred_on, Date
      attribute :supplier_country_code, CountryCode.nullable
      attribute :reverse_charge, Types::Boolean.default(false)
      attribute :payment_reference, Types::String.nullable
    end

    VoidExpense = Command(:void_expense) do
      attribute :reason, Types::String.present
    end

    # Not an expense after all, before it's filed. Once filed, it's voided.
    DiscardExpense = Command(:discard_expense)

    # The filed total in the reporting currency, from
    # Expenses::CurrencyConverter: the amount it converted (currency,
    # amount_cents, incurred_on), what it came to in which currency, and at
    # what rate. Only records data: refused once the expense isn't filed,
    # and ignored if the filed amount has changed since.
    RecordConversion = Command(:record_conversion) do
      attribute :currency, CurrencyCode
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, CurrencyCode
      attribute :reporting_cents, Integer
      attribute :rate, Types::Numeric
      attribute :rate_date, Date
    end

    # No conversion of the filed total: why, for a person to read.
    FailConversion = Command(:fail_conversion) do
      attribute :currency, CurrencyCode
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, CurrencyCode
      attribute :reason, Types::String.present
    end

    # A category's key: the baseline's (CATEGORIES), or any other, as
    # Expenses.category_key makes them.
    Category = Types::String[/\A[a-z0-9]+(?:_[a-z0-9]+)*\z/]

    # The model's category for the expense, from Expenses::Categorizer:
    # +probability+ is how likely it thinks its pick (0 to 1), and
    # +description+ what it was told the expense is. Only a suggestion:
    # ignored once a person has chosen one.
    SuggestCategory = Command(:suggest_category) do
      attribute :category, Category
      attribute :probability, Types::Numeric
      attribute :description, Types::String.present
    end

    # No suggestion for +description+: why, for a person to read.
    FailCategorization = Command(:fail_categorization) do
      attribute :description, Types::String.present
      attribute :reason, Types::String.present
    end

    # A person's category: for good, until they choose another.
    ChooseCategory = Command(:choose_category) do
      attribute :category, Category
    end

    # A person's VAT treatment: for good, until they confirm another.
    ConfirmVatTreatment = Command(:confirm_vat_treatment) do
      attribute :treatment, Types::String.options(VAT_TREATMENTS)
    end

    VatTreatment = Types::String.options(VAT_TREATMENTS)

    # Another system's expense, as it is there now: +source+ names the
    # system (freeagent), +external_id+ is the expense's id there, and the
    # expense's own id is made from both. +category+ and +vat_treatment+ are
    # the source's, mapped onto ours where they can be: suggestions here, for
    # a person to confirm. +source_category+ is the category's name there.
    # The source's books are trusted: the first files the expense, its
    # category and VAT treatment confirmed, if it has them (and a
    # description), and otherwise starts it in review. Another applies what
    # changed there, filing it again once filed: the source wins over a
    # correction made here. The same again changes nothing.
    ImportExpense = Command(:import_expense) do
      attribute :expense_id, Types::ExpenseID
      attribute :source, Types::String.present
      attribute :external_id, Types::String.present
      attribute :external_url, Types::String.nullable.default(nil)
      attribute :filing_country, CountryCode
      attribute :description, Types::String.nullable.default(nil)
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Integer
      attribute :tax_description, Types::String.nullable.default(nil)
      attribute :currency, CurrencyCode
      attribute :incurred_on, Date
      attribute :supplier_country_code, CountryCode.nullable.default(nil)
      attribute :reverse_charge, Types::Boolean.default(false)
      attribute :payment_reference, Types::String.nullable.default(nil)
      attribute :category, Category.nullable.default(nil)
      attribute :source_category, Types::String.nullable.default(nil)
      attribute :vat_treatment, VatTreatment.nullable.default(nil)
    end

    # ---- Events ----

    # Tentative figures, for a person to check: a scan's reading.
    ExpenseDrafted = Event(:expense_drafted) do
      attribute :filing_country, String
      attribute :vendor, Types::String.nullable
      attribute :description, Types::String.nullable
      attribute :net_price_cents, Types::Integer.nullable
      attribute :tax_amount_cents, Types::Integer.nullable
      attribute :tax_description, Types::String.nullable
      attribute :currency, Types::String.nullable
      attribute :incurred_on, Types::Date.nullable
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean.nullable
      attribute :payment_reference, Types::String.nullable
    end

    # New tentative figures for a drafted expense: its document read again.
    ExpenseRedrafted = Event(:expense_redrafted) do
      attribute :filing_country, String
      attribute :vendor, Types::String.nullable
      attribute :description, Types::String.nullable
      attribute :net_price_cents, Types::Integer.nullable
      attribute :tax_amount_cents, Types::Integer.nullable
      attribute :tax_description, Types::String.nullable
      attribute :currency, Types::String.nullable
      attribute :incurred_on, Types::Date.nullable
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean.nullable
      attribute :payment_reference, Types::String.nullable
    end

    # Another system's expense, its figures as they are there.
    ExpenseImported = Event(:expense_imported) do
      attribute :source, String
      attribute :external_id, String
      attribute :external_url, Types::String.nullable.default(nil)
      attribute :filing_country, String
      attribute :description, Types::String.nullable
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Integer
      attribute :tax_description, Types::String.nullable
      attribute :currency, String
      attribute :incurred_on, Date
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean
      attribute :payment_reference, Types::String.nullable
      attribute :category, Types::String.nullable
      attribute :source_category, Types::String.nullable
      attribute :vat_treatment, Types::String.nullable
    end

    # Changed at its source while in review here: its new figures are the
    # form.
    ImportedExpenseChanged = Event(:imported_expense_changed) do
      attribute :source, String
      attribute :external_id, String
      attribute :external_url, Types::String.nullable.default(nil)
      attribute :filing_country, String
      attribute :description, Types::String.nullable
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Integer
      attribute :tax_description, Types::String.nullable
      attribute :currency, String
      attribute :incurred_on, Date
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean
      attribute :payment_reference, Types::String.nullable
      attribute :category, Types::String.nullable
      attribute :source_category, Types::String.nullable
      attribute :vat_treatment, Types::String.nullable
    end

    # A person's own figures.
    ExpenseEntered = Event(:expense_entered) do
      attribute :filing_country, String
      attribute :description, String
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Integer
      attribute :tax_description, Types::String.nullable
      attribute :currency, String
      attribute :incurred_on, Date
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean
      attribute :payment_reference, Types::String.nullable
    end

    # Where it came from: the uploaded document it was read from.
    DocumentAttached = Event(:document_attached) do
      attribute :document_id, String
    end

    ExpenseFiled = Event(:expense_filed) do
      attribute :description, String
      attribute :net_price_cents, Integer
      attribute :tax_amount_cents, Integer
      attribute :tax_description, Types::String.nullable
      attribute :currency, String
      attribute :incurred_on, Date
      attribute :supplier_country_code, Types::String.nullable
      attribute :reverse_charge, Types::Boolean
      attribute :payment_reference, Types::String.nullable
    end

    VatTreatmentConfirmed = Event(:vat_treatment_confirmed) do
      attribute :treatment, String
    end

    ExpenseVoided = Event(:expense_voided) do
      attribute :reason, String
    end

    ConversionRecorded = Event(:conversion_recorded) do
      attribute :currency, String
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, String
      attribute :reporting_cents, Integer
      attribute :rate, Types::Numeric
      attribute :rate_date, Date
    end

    ConversionFailed = Event(:conversion_failed) do
      attribute :currency, String
      attribute :amount_cents, Integer
      attribute :incurred_on, Date
      attribute :reporting_currency, String
      attribute :reason, String
    end

    CategorySuggested = Event(:category_suggested) do
      attribute :category, String
      attribute :probability, Types::Numeric
      attribute :description, String
    end

    CategorizationFailed = Event(:categorization_failed) do
      attribute :description, String
      attribute :reason, String
    end

    CategoryChosen = Event(:category_chosen) do
      attribute :category, String
    end

    # ---- Domain state ----

    # The ExpenseState, evolved from the events above.
    evolve ExpenseProjector

    # ---- The statechart ----

    # Saving the form, the first time or again once filed.
    FILE_EXPENSE = proc do |_doc, cmd|
      event ExpenseFiled, cmd.payload
    end

    # The model's category, whenever it lands. A person's choice is never
    # replaced by a suggestion, and repeats change nothing.
    SUGGEST_CATEGORY = proc do
      command SuggestCategory do |doc, cmd|
        unless doc.category_chosen? || doc.category_suggestion == cmd.payload.to_h.except(:expense_id)
          event CategorySuggested, cmd.payload
        end
      end

      command FailCategorization do |doc, cmd|
        event CategorizationFailed, cmd.payload unless doc.category_chosen?
      end
    end

    # Changing their mind, once a step is done. Repeats change nothing.
    CHANGE_REVIEW = proc do
      command ChooseCategory do |doc, cmd|
        event CategoryChosen, cmd.payload unless doc.category == cmd.payload.category
      end

      command ConfirmVatTreatment do |doc, cmd|
        event VatTreatmentConfirmed, cmd.payload unless doc.vat_treatment == cmd.payload.treatment
      end
    end

    # A new draft while in review: its attached document read again. The
    # steps done stay done. Another document's, or the same draft again,
    # changes nothing.
    REDRAFT = proc do
      command DraftExpenseFromDocument do |doc, cmd|
        if doc.document_id == cmd.payload.document_id && !doc.drafted?(cmd.payload.to_h.except(:expense_id, :document_id))
          event ExpenseRedrafted, cmd.payload
        end
      end
    end

    # A complete import as its source has it: its category and VAT
    # treatment confirmed (those that differ from what's in force: taken
    # before any is appended, as appending evolves +doc+), and filed.
    FILE_IMPORT = proc do |doc, cmd|
      category, treatment = cmd.payload.category, cmd.payload.vat_treatment
      choose = !doc.category_chosen? || doc.category != category
      confirm = !doc.vat_treatment_confirmed? || doc.vat_treatment != treatment
      event CategoryChosen, category: category if choose
      event VatTreatmentConfirmed, treatment: treatment if confirm
      event ExpenseFiled, cmd.payload
    end

    # Its source's expense again: changed there, or not. Only for the same
    # source and id; the same figures again change nothing. A change that
    # brings all it takes to file it files it, as its source has it, its
    # category and VAT treatment confirmed: in review, or filed again once
    # filed.
    REIMPORT = proc do
      command ImportExpense => Filed | nil do |doc, cmd|
        next unless doc.import_changed?(cmd.payload.to_h.except(:expense_id))

        filed = !doc.filed.nil?
        event ImportedExpenseChanged, cmd.payload
        next unless ExpenseState.complete_import?(cmd.payload.to_h)

        instance_exec(doc, cmd, &FILE_IMPORT)
        to Filed unless filed
      end
    end

    initial do
      command ImportExpense => Filed | Reviewing do |doc, cmd|
        event ExpenseImported, cmd.payload
        if ExpenseState.complete_import?(cmd.payload.to_h)
          instance_exec(doc, cmd, &FILE_IMPORT)
          to Filed
        else
          to Reviewing
        end
      end

      command DraftExpenseFromDocument => Reviewing do |_doc, cmd|
        event ExpenseDrafted, cmd.payload
        event DocumentAttached, cmd.payload
      end

      command EnterExpense => Reviewing do |_doc, cmd|
        event ExpenseEntered, cmd.payload
      end
    end

    # The prefilled form, waiting for a person to choose its category and
    # confirm its VAT treatment, in either order.
    state Reviewing do
      region :category do
        initial do
          command ChooseCategory => CategoryConfirmed do |_doc, cmd|
            event CategoryChosen, cmd.payload
          end
        end
        final CategoryConfirmed
      end

      region :vat do
        initial do
          command ConfirmVatTreatment => VatConfirmed do |_doc, cmd|
            event VatTreatmentConfirmed, cmd.payload
          end
        end
        final VatConfirmed
      end

      done Reviewed

      # A step already done, changed while the other waits: its region is
      # final, so the change comes here.
      instance_exec(&CHANGE_REVIEW)
      instance_exec(&SUGGEST_CATEGORY)
      instance_exec(&REDRAFT)
      instance_exec(&REIMPORT)
      command DiscardExpense => Discarded
    end

    # Category and VAT treatment confirmed: ready to file.
    state Reviewed do
      command SaveExpense => Filed, &FILE_EXPENSE
      instance_exec(&SUGGEST_CATEGORY)
      instance_exec(&CHANGE_REVIEW)
      instance_exec(&REDRAFT)
      instance_exec(&REIMPORT)
      command DiscardExpense => Discarded
    end

    # Corrections are saved in place, re-entering filed. The category and
    # VAT treatment stay as confirmed, unless a person changes them. A new
    # draft changes nothing: what was filed stands.
    state Filed do
      command SaveExpense => Filed, &FILE_EXPENSE
      instance_exec(&REIMPORT)
      instance_exec(&SUGGEST_CATEGORY)
      instance_exec(&CHANGE_REVIEW)

      command VoidExpense => Voided do |_doc, cmd|
        event ExpenseVoided, cmd.payload
      end

      # The conversion, for the total as filed now: one of an amount since
      # corrected is dropped (the correction's comes after it), and so is
      # one already recorded.
      command RecordConversion do |doc, cmd|
        converted = cmd.payload.to_h.except(:expense_id)
        if doc.converting?(**converted.slice(:currency, :amount_cents, :incurred_on)) && doc.converted != converted
          event ConversionRecorded, cmd.payload
        end
      end

      command FailConversion do |doc, cmd|
        failure = cmd.payload.to_h.except(:expense_id)
        if doc.converting?(**failure.slice(:currency, :amount_cents, :incurred_on)) && doc.conversion_failure != failure
          event ConversionFailed, cmd.payload
        end
      end
    end

    final Discarded
    final Voided
  end
end
