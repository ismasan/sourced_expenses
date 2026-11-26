# frozen_string_literal: true

module UI
  # One expense: its draft to review, the steps of the review, the filed
  # expense. One drafted from a document shows the document beside it, and
  # whether it's being read again; one drafted by hand (NewExpensePage), or
  # by any other source, has nothing beside it.
  #
  # The new expense form and a document once read both lead here, so the
  # page often renders before the machine has decided the command that
  # starts it: it shows
  # "Drafting…" and reloads as the expense's events arrive on its channel.
  class ExpensePage < RecordPage
    MACHINE = Expenses::Expense
    ID_TYPE = Types::ExpenseID
    NOUN = :expense

    path '/expenses/:expense_id'
    # Anything else in the path is a 400.
    query_schema expense_id: Types::ExpenseID

    E = Expenses::Expense
    D = Expenses::Document

    # Every event the expense's machine evolves, its states included, and its
    # document's: a rescan shows here as it goes.
    on E, D

    include ExpenseFields

    # Forms must be for commands the expense accepts as it is now.
    with_machine { @machine }

    TRACK = %w[Draft Review File].freeze
    TRACK_AT = { 'drafting' => 0, 'reviewing' => 1, 'reviewed' => 2, 'filed' => 2 }.freeze

    def initialize(id, history)
      super
      @document = MachineHistory.load(D, @doc.document_id).machine if @doc.document_id
    end

    private

    # Its document's channel too: a rescan, and what it reads, show here.
    def own_channels
      channels = super
      channels << "documents.#{channel_segment(@doc.document_id)}" if @doc.document_id
      channels
    end

    def back_link = ['All expenses', ExpensesPage.path]

    def render_title = plain(@doc.draft[:description] || 'New expense')

    def preview? = !@document.nil?

    # Its document, with a link to its page, and where its scan is.
    # One cell of the body's grid, the panel being the other.
    def render_preview
      div do
        render_file_preview(@document.context)
        p(class: 'filed__note') do
          a(href: "/documents/#{@doc.document_id}") { 'Its document' }
          plain ": #{Status.for(@document.machine.paths, machine: :document).label}"
        end
      end
    end

    def render_panel(kind)
      case kind
      when 'drafting' then lead('Drafting the expense. Nothing for you to do yet.')
      when 'reviewing' then render_review
      when 'reviewed' then render_reviewed
      when 'filed' then render_filed
      else lead("This expense was #{status_word}. It isn’t in your expenses.")
      end
    end

    def status_word = paths.include?('voided') ? 'voided' : 'discarded'

    # Its document, read again: the draft is replaced once it's done.
    def rescanning? = @document && Status.for(@document.machine.paths, machine: :document).stage == :working

    # Read its document again, while it's in review; discard it.
    def actions(primary: nil, final: false, &)
      list = []
      list << [D::Rescan, 'Scan again', { document_id: @doc.document_id }] if rescan?
      list << [E::DiscardExpense, 'Discard'] if can?(E::DiscardExpense)
      render_actions(list, primary:, final:, &)
    end

    # A rescan replaces the draft, so only while in review, and only if its
    # document can be read again now.
    def rescan?
      @document&.available_commands&.include?(D::Rescan) && can?(E::DiscardExpense)
    end

    # Two steps, in either order, before the form can be filed: the
    # category and the VAT treatment. The draft is shown, for the VAT
    # treatment's sake: it's suggested from these figures.
    def render_review
      lead('Your turn. Choose the category and confirm the VAT treatment, in either order. Then check the form and file it.')
      render_rescanning
      render_draft
      render_category
      render_vat
      actions(final: true)
    end

    # Both steps done: the form, to correct, then the two steps, then filing
    # it: the review's last step, with the other ways out beside it. The
    # button is outside the form, so it names it.
    def render_reviewed
      lead('Category and VAT treatment confirmed. Check the form, correct anything that’s wrong, and file it.')
      render_rescanning
      render_form(id: REVIEW_FORM)
      render_category
      render_vat
      actions(final: true) do
        button(type: :submit, form: REVIEW_FORM, class: 'button button--primary') { 'File expense' }
      end
    end

    def render_rescanning
      p(class: 'filed__note') { 'Its document is being read again: the draft is replaced once it’s done.' } if rescanning?
    end

    REVIEW_FORM = 'review-form'

    # The draft, or a note that there's nothing in it yet.
    def render_draft
      draft = @doc.draft || {}
      unless draft[:net_price_cents]
        p(class: 'filed__note') { 'Nothing in the draft yet: you’ll fill in the form once both steps are done.' }
        return
      end

      # A draft's figures are tentative; a person's are their own.
      render_origin
      net, tax, currency = draft.values_at(:net_price_cents, :tax_amount_cents, :currency)
      tax = tax.to_i
      dl(class: 'filed') do
        dt { 'Description' }
        dd { draft[:description] }
        dt { 'Total' }
        dd { format('%.2f %s', (net + tax) / 100.0, currency) }
        dt { 'Of which VAT' }
        dd do
          plain format('%.2f %s', tax / 100.0, currency)
          plain ', reverse charged' if draft[:reverse_charge]
        end
        dt { 'Supplier country' }
        dd { draft[:supplier_country_code] || span(class: 'filed__note') { 'Unknown' } }
        dt { 'Date' }
        dd { draft[:incurred_on].to_s }
      end
    end

    # ---- The category ----

    # The model's suggestion, or the person's choice, and a list to choose
    # another from. Choosing the suggested one confirms it.
    def render_category
      return unless can?(E::ChooseCategory)

      section(class: 'category', aria: { label: 'Category' }) do
        p(class: 'category__status') do
          if @doc.category_chosen?
            plain 'Category: '
            strong { Expenses.category_label(@doc.category) }
          elsif (suggestion = @doc.category_suggestion) && suggestion[:source]
            plain "Category on #{source_name}: "
            strong { Expenses.category_label(suggestion[:category]) }
            span(class: 'filed__note') { '. Choose it to confirm, or choose another.' }
          elsif suggestion
            plain 'Suggested category: '
            strong { Expenses.category_label(suggestion[:category]) }
            span(class: 'filed__note') { format(' (%d%% sure). Choose it to confirm, or choose another.', suggestion[:probability] * 100) }
          elsif (failure = @doc.categorization_failure)
            plain 'No category suggested: '
            span(class: 'filed__note') { failure[:reason] }
          elsif @doc.draft[:description]
            span(class: 'filed__note') { 'Suggesting a category…' }
          else
            span(class: 'filed__note') { 'Nothing in the draft to suggest one from: choose a category.' }
          end
        end
        # A suggestion isn't chosen yet: the list shows it dashed, and the
        # button confirms it.
        suggested = !@doc.category_chosen? && @doc.category
        command E::ChooseCategory, class: ['category__form', ('category__form--suggested' if suggested)] do |f|
          f.payload_fields(expense_id: @id)
          select(name: 'command[payload][category]', aria: { label: 'Category' }) do
            option(value: '', disabled: true, selected: @doc.category.nil?) { 'Choose a category' }
            # The baseline's, then every other one expenses have had.
            Expenses::CategoryList.all(Sidereal.config['db']).each do |choice|
              option(value: choice.key, title: choice.description, selected: choice.key == @doc.category) { choice.label }
            end
          end
          if suggested
            button(type: :submit, class: 'button button--primary button--suggested') { 'Confirm' }
          else
            button(type: :submit, class: 'button') { @doc.category_chosen? ? 'Change' : 'Choose' }
          end
        end
      end
    end

    # The form, with its own +submit+ button, or none for one outside it
    # (with form: +id+).
    def render_form(submit = nil, id: nil)
      draft = (@doc.draft || {}).compact
      command E::SaveExpense.new(payload: { expense_id: @id, **draft }), class: 'review-form', id: do |f|
        f.payload_fields(expense_id: @id)
        expense_fields(f)
        button(type: :submit, class: 'button button--primary') { submit } if submit
      end
    end

    # ---- Filed ----

    # The total in the reporting currency, once Expenses::CurrencyConverter
    # has it: nothing to show for an expense in that currency already.
    def render_conversion(filed)
      currency = Sidereal.config['reporting_currency']
      return if filed[:currency] == currency

      dt { "In #{currency}" }
      dd do
        if (converted = @doc.converted) && converted[:reporting_currency] == currency
          plain format('%.2f %s', converted[:reporting_cents] / 100.0, currency)
          span(class: 'filed__note') { " at #{converted[:rate]} on #{converted[:rate_date].strftime('%-d %b %Y')}" }
        elsif (failure = @doc.conversion_failure) && failure[:reporting_currency] == currency
          span(class: 'filed__note') { "Not converted: #{failure[:reason]}" }
        else
          span(class: 'filed__note') { 'Converting…' }
        end
      end
    end

    VAT_LABELS = {
      'domestic' => 'Domestic', 'import' => 'Import', 'reverse_charge' => 'Reverse charge',
      'foreign_vat' => 'Foreign VAT', 'no_vat' => 'No VAT'
    }.freeze

    # The rule's suggestion, or the person's treatment, and a button for
    # each. Choosing the suggested one confirms it.
    def render_vat
      return unless can?(E::ConfirmVatTreatment)

      confirmed = @doc.vat_treatment_confirmed?
      suggested = @doc.suggested_vat_treatment
      section(class: 'category', aria: { label: 'VAT treatment' }) do
        p(class: 'category__status') do
          if confirmed
            plain 'VAT treatment: '
            strong { VAT_LABELS.fetch(@doc.vat_treatment, @doc.vat_treatment) }
          elsif suggested.nil?
            plain 'VAT treatment: '
            span(class: 'filed__note') { 'nothing in the draft to suggest one from. Choose one.' }
          else
            plain 'Suggested VAT treatment: '
            strong { VAT_LABELS.fetch(suggested, suggested) }
            note = @doc.vat_needs_review? ? ' Another country’s VAT: check it closely.' : ''
            span(class: 'filed__note') { "#{note} Choose it to confirm, or choose another." }
          end
        end
        div(class: 'actions', role: 'group', aria: { label: 'VAT treatment' }) do
          Expenses::VAT_TREATMENTS.each do |treatment|
            current = @doc.vat_treatment.to_s == treatment
            label = VAT_LABELS[treatment]
            if current && confirmed
              # Chosen already: nothing to do.
              action(E::ConfirmVatTreatment, label, treatment:, selected: true, disabled: true)
            elsif current
              # Suggested: choosing it confirms it.
              action(E::ConfirmVatTreatment, "Confirm #{label}", treatment:, selected: false, suggested: true)
            else
              action(E::ConfirmVatTreatment, label, treatment:, selected: false)
            end
          end
        end
      end
    end

    # Where the form's figures came from, when they aren't a person's: what
    # to check them against.
    def render_origin
      if @doc.imported?
        p(class: 'filed__note') do
          plain "Imported from #{source_name}: check it, then confirm its category and VAT treatment."
          render_source_link
        end
      elsif @doc.document? && !@doc.entered?
        p(class: 'filed__note') { 'Read from its document: check it against the file.' }
      end
    end

    # The system an imported expense came from, as a person reads it.
    SOURCES = { 'freeagent' => 'FreeAgent' }.freeze
    def source_name = SOURCES.fetch(@doc.source, @doc.source)

    # A link to it on the system it was imported from, when it has one.
    def render_source_link
      return unless @doc.external_url

      plain ' '
      a(href: @doc.external_url, target: '_blank', rel: 'noopener') { "Open in #{source_name}" }
    end

    def render_filed
      filed = @doc.filed
      if @doc.imported?
        lead("Filed, as it is on #{source_name}. It’s in your expenses.")
        p(class: 'filed__note') { render_source_link } if @doc.external_url
      else
        lead('Filed. It’s in your expenses.')
      end
      dl(class: 'filed') do
        dt { 'Description' }
        dd { filed[:description] }
        dt { 'Total' }
        dd { format('%.2f %s', (filed[:net_price_cents] + filed[:tax_amount_cents]) / 100.0, filed[:currency]) }
        render_conversion(filed)
        dt { 'Of which VAT' }
        dd { format('%.2f %s', filed[:tax_amount_cents] / 100.0, filed[:currency]) }
        dt { 'Date' }
        dd { filed[:incurred_on].to_s }
        dt { 'Category' }
        dd { plain Expenses.category_label(@doc.category) }
        dt { 'VAT treatment' }
        dd { VAT_LABELS.fetch(@doc.vat_treatment.to_s, @doc.vat_treatment.to_s) }
      end

      render_category
      render_vat

      details(class: 'filed__edit') do
        summary { 'Correct it' }
        if @doc.imported?
          p(class: 'filed__note') { "#{source_name}’s next change to it replaces a correction made here: correct it there." }
        end
        render_form('Save changes')
      end

      return unless can?(E::VoidExpense)

      command E::VoidExpense, class: 'void-form' do |f|
        f.payload_fields(expense_id: @id)
        field('Reason to void it') { f.text_field :reason }
        button(type: :submit, class: 'button') { 'Void' }
      end
    end
  end
end
