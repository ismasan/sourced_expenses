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
    query_schema expense_id: Types::UUID::V4

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
      return unless Types::UUID::V4 === expense_id

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
      status = Status.for(paths)
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
      'reviewing' => 2, 'vat_review' => 3, 'filed' => 3
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
      when 'rejected'
        lead('This doesn’t look like a receipt or invoice. Fill it in by hand if it is one, or discard it.')
        blockquote(class: 'reason') { @doc.verification&.dig(:explanation) }
        actions(primary: E::EnterManually)
      when 'failed'
        lead('The scan stopped before it finished. Scan it again, or fill it in by hand.')
        blockquote(class: 'reason') { @doc.failure&.dig(:reason) }
        actions(primary: E::Rescan)
      when 'filed', 'vat_review' then render_filed
      else lead("This upload was #{status_word}. It isn’t in your expenses.")
      end
    end

    # What the panel is about, and whose move it is.
    def lead(text) = p(class: 'panel-lead') { text }

    def status_word = paths.include?('voided') ? 'voided' : 'discarded'

    # The prefilled form: what the scan read, for a person to check and save.
    def render_review
      lead('Your turn. Check what was read, correct anything that’s wrong, and save it as an expense.')
      render_form('Save expense')
      actions
    end

    def render_form(submit)
      draft = (@doc.draft || {}).compact
      command E::SaveExpense.new(payload: { expense_id: @expense_id, **draft }), class: 'review-form' do |f|
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
          field('Supplier country') { f.text_field :supplier_country_code, maxlength: 2, placeholder: 'NL' }
        end
        field('Payment reference') { f.text_field :payment_reference }
        label(class: 'review-form__check') do
          f.check_box :reverse_charge
          span { 'VAT reverse charged' }
        end
        button(type: :submit, class: 'button button--primary') { submit }
      end
    end

    def field(name, &)
      label(class: 'review-form__field') do
        span { name }
        yield
      end
    end

    # Rescan, fill in by hand, discard: whichever the expense accepts now.
    # +primary+, the one to offer first, in the call-to-action colour.
    def actions(primary: nil)
      div(class: 'actions') do
        [[E::EnterManually, 'Fill in by hand'], [E::Rescan, 'Scan again'], [E::DiscardDocument, 'Discard']]
          .select { |klass, _| can?(klass) }
          .partition { |klass, _| klass == primary }.flatten(1)
          .each { |klass, text| action(klass, text, primary: klass == primary) }
      end
    end

    # +selected+ marks the button for what's already chosen (aria-pressed);
    # +disabled+ when choosing it again would change nothing.
    def action(klass, text, primary: false, selected: nil, disabled: false, **fields)
      command klass, key: fields.values.join('-').then { it.empty? ? 'cmd' : it } do |f|
        f.payload_fields(expense_id: @expense_id, **fields)
        button(type: :submit, disabled:,
               class: ['button', ('button--primary' if primary && !selected), ('button--selected' if selected)],
               aria: { pressed: selected.nil? ? nil : selected.to_s }) { text }
      end
    end

    # ---- Filed ----

    # The total in US dollars, once Expenses::USDConverter has it: nothing
    # to show for an expense in dollars already.
    def render_usd(filed)
      return if filed[:currency] == 'USD'

      dt { 'In US dollars' }
      dd do
        if (usd = @doc.usd)
          plain format('%.2f USD', usd[:usd_cents] / 100.0)
          span(class: 'filed__note') { " at #{usd[:rate]} on #{usd[:rate_date].strftime('%-d %b %Y')}" }
        elsif (failure = @doc.usd_failure)
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

    def render_filed
      filed = @doc.filed
      lead('Filed. It’s in your expenses.') unless paths.include?('filed.vat_needs_review')
      dl(class: 'filed') do
        dt { 'Description' }
        dd { filed[:description] }
        dt { 'Total' }
        dd { format('%.2f %s', (filed[:net_price_cents] + filed[:tax_amount_cents]) / 100.0, filed[:currency]) }
        render_usd(filed)
        dt { 'Of which VAT' }
        dd { format('%.2f %s', filed[:tax_amount_cents] / 100.0, filed[:currency]) }
        dt { 'Date' }
        dd { filed[:incurred_on].to_s }
        dt { 'VAT treatment' }
        dd do
          plain VAT_LABELS.fetch(@doc.vat_treatment.to_s, @doc.vat_treatment.to_s)
          plain(@doc.vat_treatment_confirmed? ? ', confirmed' : ', suggested')
        end
      end

      if can?(E::Filed::ConfirmVatTreatment)
        confirmed = @doc.vat_treatment_confirmed?
        if paths.include?('filed.vat_needs_review')
          lead("Your turn. This has another country’s VAT. Suggested: #{VAT_LABELS[@doc.vat_treatment.to_s]}. Choose it to confirm, or choose another.")
        elsif confirmed
          p { 'How the VAT is treated. Choose another to change it:' }
        else
          p { "Suggested from the document: #{VAT_LABELS[@doc.vat_treatment.to_s]}. Choose it to confirm, or choose another:" }
        end
        div(class: 'actions', role: 'group', aria: { label: 'VAT treatment' }) do
          Expenses::VAT_TREATMENTS.each do |treatment|
            current = @doc.vat_treatment.to_s == treatment
            # Choosing the suggested one confirms it; the confirmed one is chosen already.
            action(E::Filed::ConfirmVatTreatment, VAT_LABELS[treatment], treatment:, selected: current, disabled: current && confirmed,
                                                        primary: paths.include?('filed.vat_needs_review'))
          end
        end
      end

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
