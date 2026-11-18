# frozen_string_literal: true

module UI
  # One uploaded document, in two tabs: the Submission tab (its preview,
  # where its scan is, and what a person can do with it now) and the Diagram
  # tab (SubmissionDiagramPage: the Expense statechart with its live state
  # lit). Both have its history in a sidebar.
  #
  # Each tab is a page of its own, at its own path, so a live update and a
  # step of time travel each stay on the tab on screen. This class is the
  # Submission tab; subclasses set their path and #tab and render #render_tab.
  #
  # The page renders the expense as it is now, or as it was after any step
  # of its history (.at): the history's links travel there. A past step is a
  # static render: it listens to nothing, and its forms are disabled, since
  # a command would apply to the expense as it is now.
  #
  # The upload form redirects here straight away, so the page often renders
  # before the machine has decided UploadDocument: it shows "Uploading…" and
  # reloads as the expense's events arrive on its channel.
  class SubmissionPage < Sidereal::Page
    path '/submissions/:expense_id'
    # Anything else in the path is a 400.
    query_schema expense_id: Types::ExpenseID

    E = Expenses::Expense

    # Every event the expense's machine evolves, its states included.
    on E

    # Forms must be for commands the expense accepts as it is now.
    with_machine { @expense }

    TABS = { submission: 'Submission', diagram: 'Diagram' }.freeze

    # This page's key in TABS.
    def tab = :submission

    def self.load(params, _ctx)
      expense_id = params[:expense_id]
      new(expense_id, SubmissionHistory.load(expense_id))
    end

    # The page at +step+ of the expense's history, or nil when there's no such step.
    def self.at(expense_id, step)
      return unless Types::ExpenseID === expense_id

      history = SubmissionHistory.load(expense_id, step:)
      new(expense_id, history) if step.between?(1, history.messages.size)
    end

    def initialize(expense_id, history)
      @expense_id = expense_id
      @history = history
      @expense = history.expense
      @doc = @expense.context
    end

    def live? = @history.live?

    # A past step listens to nothing, and has no page_key for an update to reload.
    def channel_name = live? ? "expenses.#{@expense_id}" : nil
    def page_signals = live? ? super : {}

    def view_template
      status = @status = Status.for(paths)
      div(id: 'submission-page', class: ['submission-page', "submission-page--#{status.stage}"]) do
        p(class: 'submission-page__back') { a(href: '/') { 'All uploads' } }

        render_time_travel unless live?

        header(class: 'submission-page__header') do
          h1(class: 'submission-page__title') { @doc.filename || 'New upload' }
          render Components::StatusBadge.new(status, size: :large)
        end
        render_track(status)

        render_tabs
        div(class: 'submission-page__tab', role: 'tabpanel', aria: { label: TABS.fetch(tab) }) do
          render_tab(status.kind)
        end

        render Components::HistoryFeed.new(
          messages: @history.messages,
          current_step: @history.current_step,
          live: live?,
          live_href: page_path,
          step_href: ->(step) { page_path(step) },
          prefix: 'expenses.',
          hide: %i[expense_id]
        )
      end
    end

    private

    def paths = @expense.machine.paths

    # This submission's page for +tab+, live or at +step+.
    def page_path(step = nil, tab: self.tab)
      path = tab == :submission ? "/submissions/#{@expense_id}" : "/submissions/#{@expense_id}/#{tab}"
      step ? "#{path}/at/#{step}" : path
    end

    TRACK = %w[Upload Scan Review File].freeze

    # Where the kinds sit on the track: the stage it's at, by index.
    TRACK_AT = {
      'uploading' => 0, 'scanning' => 1, 'rejected' => 1, 'failed' => 1,
      'reviewing' => 2, 'reviewed' => 3, 'filed' => 3
    }.freeze

    # The four stages an upload goes through, the one it's at in its status
    # colour. A closed one (discarded, voided) is greyed out whole.
    def render_track(status)
      at = TRACK_AT[status.kind]
      ol(class: ['track', ('track--closed' if at.nil?)], aria: { label: 'Progress' }) do
        TRACK.each_with_index do |name, index|
          state = if at.nil? then 'todo'
                  elsif index < at then 'past'
                  elsif index == at then 'current'
                  else 'todo'
                  end
          li(class: "track__stage track__stage--#{state}", aria: { current: state == 'current' ? 'step' : nil }) do
            span(class: 'track__name') { name }
          end
        end
      end
    end

    # Plain links: each tab is a page of its own. At a past step, the other
    # tab opens at the same step.
    def render_tabs
      nav(class: 'tabs', aria: { label: 'Submission views' }) do
        TABS.each do |key, label|
          current = key == tab
          a(href: page_path(@history.step, tab: key), class: ['tabs__tab', ('tabs__tab--current' if current)],
            aria: { current: current ? 'page' : nil }) { label }
        end
      end
    end

    # The Submission tab: the file, and what a person can do with it now.
    def render_tab(kind)
      div(class: 'submission-page__body') do
        render_preview
        div(class: 'submission-page__panel') do
          if live?
            render_panel(kind)
          else
            fieldset(class: 'submission-page__frozen', disabled: true) { render_panel(kind) }
          end
        end
      end
    end

    def render_time_travel
      message = @history.messages[@history.current_step - 1]
      p(class: 'time-travel', role: 'status') do
        span do
          plain "Step #{@history.current_step} of #{@history.messages.size}: as it was after "
          code { message.type.delete_prefix('expenses.') }
        end
        a(href: page_path) { 'Back to live' }
      end
    end

    def can?(command) = @expense.available_commands.include?(command)

    # ---- The file ----

    # The thumbnail opens the file in a dialog. The dialog is left alone when
    # the page re-renders (data-ignore-morph), so an update doesn't close it.
    def render_preview
      file_id = @doc.file_ref
      figure(class: 'preview') do
        if file_id
          button(type: 'button', class: 'preview__thumb', aria: { label: "Open #{@doc.filename}" },
                 data: { 'on:click' => "document.getElementById('file-dialog').showModal()" }) do
            img(src: "/files/#{file_id}/thumbnail", alt: "Preview of #{@doc.filename}", loading: 'lazy')
          end
          figcaption { 'Open full size' }
          render_dialog(file_id)
        else
          div(class: 'preview__placeholder') { 'Uploading' }
        end
      end
    end

    def render_dialog(file_id)
      dialog(id: 'file-dialog', class: 'file-dialog', data: { 'ignore-morph' => true, 'on:click' => 'evt.target === el && el.close()' }) do
        form(method: 'dialog', class: 'file-dialog__bar') do
          span(class: 'file-dialog__name') { @doc.filename }
          a(href: "/files/#{file_id}", target: '_blank', rel: 'noopener') { 'Open in a new tab' }
          button(type: 'submit', aria: { label: 'Close' }) { '×' }
        end
        if @doc.content_type == 'application/pdf'
          # Fitted to the width (a PDF open parameter): the viewer's default
          # fits the whole page, which leaves a receipt tiny. No page thumbnails
          # sidebar either: receipts are a page or two.
          iframe(src: "/files/#{file_id}#view=FitH&navpanes=0", title: @doc.filename, class: 'file-dialog__file')
        else
          img(src: "/files/#{file_id}", alt: @doc.filename, class: 'file-dialog__file')
        end
      end
    end

    # ---- What a person can do now ----

    def render_panel(kind)
      case kind
      when 'uploading' then lead('Storing the file. Nothing for you to do yet.')
      when 'scanning'
        lead('Reading the document. Nothing for you to do yet: a form to check fills in here when it’s done.')
        actions
      when 'reviewing' then render_review
      when 'reviewed' then render_reviewed
      when 'rejected'
        lead('This doesn’t look like a receipt or invoice. Fill it in by hand if it is one, or discard it.')
        blockquote(class: 'reason') { @doc.verification&.dig(:explanation) }
        actions(primary: E::EnterManually)
      when 'failed'
        lead('The scan stopped before it finished. Scan it again, or fill it in by hand.')
        blockquote(class: 'reason') { @doc.failure&.dig(:reason) }
        actions(primary: E::Rescan)
      when 'filed' then render_filed
      else lead("This upload was #{status_word}. It isn’t in your expenses.")
      end
    end

    # What the panel is about, and whose move it is: called out for
    # attention when it's a person's.
    def lead(text) = p(class: ['panel-lead', ('callout--attention' if @status&.stage == :yours)]) { text }

    def status_word = paths.include?('voided') ? 'voided' : 'discarded'

    # Two steps, in either order, before the form can be filed: the
    # category and the VAT treatment. What the scan read is shown, for
    # the VAT treatment's sake: it's suggested from these figures.
    def render_review
      lead('Your turn. Choose the category and confirm the VAT treatment, in either order. Then check the form and file it.')
      render_draft
      render_category
      render_vat
      actions(final: true)
    end

    # Both steps done: the form, to correct, then the two steps, then filing
    # it: the review's last step, with the other ways out beside it. The
    # button is outside the form, so it names it.
    def render_reviewed
      lead('Category and VAT treatment confirmed. Check what was read, correct anything that’s wrong, and file it.')
      render_form(id: REVIEW_FORM)
      render_category
      render_vat
      actions(final: true) do
        button(type: :submit, form: REVIEW_FORM, class: 'button button--primary') { 'File expense' }
      end
    end

    REVIEW_FORM = 'review-form'

    # What the scan read, or nothing yet for a form filled in by hand.
    def render_draft
      draft = @doc.draft || {}
      unless draft[:net_price_cents]
        p(class: 'filed__note') { 'Nothing was read: you’ll fill in the form once both steps are done.' }
        return
      end

      net, tax, currency = draft.values_at(:net_price_cents, :tax_amount_cents, :currency)
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
          elsif (suggestion = @doc.category_suggestion)
            plain 'Suggested category: '
            strong { Expenses.category_label(suggestion[:category]) }
            span(class: 'filed__note') { format(' (%d%% sure). Choose it to confirm, or choose another.', suggestion[:probability] * 100) }
          elsif (failure = @doc.categorization_failure)
            plain 'No category suggested: '
            span(class: 'filed__note') { failure[:reason] }
          elsif @doc.extraction
            span(class: 'filed__note') { 'Suggesting a category…' }
          else
            span(class: 'filed__note') { 'Nothing was read to suggest one from: choose a category.' }
          end
        end
        # A suggestion isn't chosen yet: the list shows it dashed, and the
        # button confirms it.
        suggested = !@doc.category_chosen? && @doc.category
        command E::ChooseCategory, class: ['category__form', ('category__form--suggested' if suggested)] do |f|
          f.payload_fields(expense_id: @expense_id)
          select(name: 'command[payload][category]', aria: { label: 'Category' }) do
            option(value: '', disabled: true, selected: @doc.category.nil?) { 'Choose a category' }
            Expenses::CATEGORIES.each do |key, (label, description)|
              option(value: key, title: description, selected: key == @doc.category) { label }
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
      command E::SaveExpense.new(payload: { expense_id: @expense_id, **draft }), class: 'review-form', id: do |f|
        f.payload_fields(expense_id: @expense_id)
        field('Description') { f.text_field :description }
        div(class: 'review-form__row') do
          field('Net amount (cents)') { f.number_field :net_price_cents, step: 1 }
          field('VAT amount (cents)') { f.number_field :tax_amount_cents, step: 1 }
          field('Currency') { f.text_field :currency, maxlength: 3, placeholder: 'EUR' }
        end
        field('VAT description') { f.text_field :tax_description, placeholder: 'BTW 21%' }
        div(class: 'review-form__row') do
          field('Date') { f.date_field :incurred_on }
          field('Supplier country') { f.text_field :supplier_country_code, maxlength: 2, placeholder: 'GB' }
        end
        field('Payment reference') { f.text_field :payment_reference }
        label(class: 'review-form__check') do
          f.check_box :reverse_charge
          span { 'VAT reverse charged' }
        end
        button(type: :submit, class: 'button button--primary') { submit } if submit
      end
    end

    def field(name, &)
      label(class: 'review-form__field') do
        span { name }
        yield
      end
    end

    # Rescan, fill in by hand, discard: whichever the expense accepts now.
    # +primary+, the one to offer first, in the call-to-action colour. A
    # block renders what goes before them all. +final+ for the row that
    # ends a review, set apart from the steps above it.
    def actions(primary: nil, final: false)
      div(class: ['actions', ('actions--final' if final)]) do
        yield if block_given?
        [[E::EnterManually, 'Fill in by hand'], [E::Rescan, 'Scan again'], [E::DiscardDocument, 'Discard']]
          .select { |klass, _| can?(klass) }
          .partition { |klass, _| klass == primary }.flatten(1)
          .each { |klass, text| action(klass, text, primary: klass == primary) }
      end
    end

    # +selected+ marks the button for what's already chosen (aria-pressed);
    # +suggested+ for what's proposed but not chosen yet, which choosing
    # confirms; +disabled+ when choosing it again would change nothing.
    def action(klass, text, primary: false, selected: nil, suggested: false, disabled: false, **fields)
      command klass, key: fields.values.join('-').then { it.empty? ? 'cmd' : it } do |f|
        f.payload_fields(expense_id: @expense_id, **fields)
        button(type: :submit, disabled:,
               class: ['button', ('button--primary' if (primary || suggested) && !selected), ('button--selected' if selected),
                       ('button--suggested' if suggested)],
               aria: { pressed: selected.nil? ? nil : selected.to_s }) { text }
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
            span(class: 'filed__note') { 'nothing was read to suggest one from. Choose one.' }
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

    def render_filed
      filed = @doc.filed
      lead('Filed. It’s in your expenses.')
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
        dd do
          plain Expenses.category_label(@doc.category)
        end
        dt { 'VAT treatment' }
        dd { VAT_LABELS.fetch(@doc.vat_treatment.to_s, @doc.vat_treatment.to_s) }
      end

      render_category
      render_vat

      details(class: 'filed__edit') do
        summary { 'Correct it' }
        render_form('Save changes')
      end

      if can?(E::VoidExpense)
        command E::VoidExpense, class: 'void-form' do |f|
          f.payload_fields(expense_id: @expense_id)
          field('Reason to void it') { f.text_field :reason }
          button(type: :submit, class: 'button') { 'Void' }
        end
      end
    end
  end
end
