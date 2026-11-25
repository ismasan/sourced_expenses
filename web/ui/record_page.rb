# frozen_string_literal: true

module UI
  # A page for one document (DocumentPage) or one expense (ExpensePage), in
  # two tabs: what it is and what a person can do with it now, and the
  # Diagram tab (DiagramTab: its machine's statechart with its live state
  # lit). Both have its history in a sidebar.
  #
  # Each tab is a page of its own, at its own path, so a live update and a
  # step of time travel each stay on the tab on screen. A subclass names its
  # machine (MACHINE), its noun and its track, and renders #render_title and
  # #render_panel; a diagram subclass renders #render_tab.
  #
  # The page renders its machine as it is now, or as it was after any step
  # of its history (.at): the history's links travel there. A past step is a
  # static render: it listens to nothing, and its forms are disabled, since
  # a command would apply to the machine as it is now.
  class RecordPage < Page
    stylesheet 'ui/record_page.css', path: 'record_page.css'
    stylesheet 'ui/diagram_tab.css', path: 'diagram_tab.css'

    TABS = { main: 'Details', diagram: 'Diagram' }.freeze

    # This page's key in TABS.
    def tab = :main

    # Every event the machine evolves, its states included.
    def self.machine_class = self::MACHINE

    # The id in the path, and where the record's pages are.
    def self.key = machine_class.partition_keys.first
    def self.base_path = "/#{machine_class.message_prefix}"

    # The id's type, for a path given by hand (time travel's).
    def self.id_type = self::ID_TYPE

    def self.load(params, _ctx)
      id = params[key]
      new(id, MachineHistory.load(machine_class, id))
    end

    # The page at +step+ of the record's history, or nil when there's no such step.
    def self.at(id, step)
      return unless id_type === id

      history = MachineHistory.load(machine_class, id, step:)
      new(id, history) if step.between?(1, history.messages.size)
    end

    def initialize(id, history)
      @id = id
      @history = history
      @machine = history.machine
      @doc = @machine.context
    end

    def live? = @history.live?

    # Its own channel, and the system ones. A past step listens only to
    # those, and has no page_key for an update to reload.
    def channel_names = live? ? [*own_channels, *SYSTEM_CHANNELS] : SYSTEM_CHANNELS
    def page_signals = live? ? super : {}

    def view_template
      status = @status = Status.for(paths, machine: noun_key)
      div(id: 'record-page', class: ['record-page', "record-page--#{status.stage}"]) do
        p(class: 'record-page__back') { a(href: back_link[1]) { back_link[0] } }

        render_time_travel unless live?

        header(class: 'record-page__header') do
          h1(class: 'record-page__title') { render_title }
          render Components::StatusBadge.new(status, size: :large)
        end
        render_track(status)

        render_tabs
        div(class: 'record-page__tab', role: 'tabpanel', aria: { label: TABS.fetch(tab) }) do
          render_tab(status.kind)
        end

        render Components::HistoryFeed.new(
          messages: @history.messages,
          current_step: @history.current_step,
          live: live?,
          live_href: page_path,
          step_href: ->(step) { page_path(step) },
          prefix: "#{self.class.machine_class.message_prefix}.",
          hide: [self.class.key]
        )
      end
    end

    private

    def own_channels = ["#{self.class.machine_class.message_prefix}.#{channel_segment(@id)}"]

    def paths = @machine.machine.paths

    # :document or :expense, for Status.
    def noun_key = self.class::NOUN

    # This record's page for +tab+, live or at +step+.
    def page_path(step = nil, tab: self.tab)
      path = "#{self.class.base_path}/#{@id}"
      path = "#{path}/#{tab}" unless tab == :main
      step ? "#{path}/at/#{step}" : path
    end

    # The stages along the track, and the one each kind is at, by index.
    def track = self.class::TRACK
    def track_at = self.class::TRACK_AT

    # The stages it goes through, the one it's at in its status colour. A
    # closed one (discarded, voided) is greyed out whole.
    def render_track(status)
      at = track_at[status.kind]
      ol(class: ['track', ('track--closed' if at.nil?)], aria: { label: 'Progress' }) do
        track.each_with_index do |name, index|
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
      nav(class: 'tabs', aria: { label: 'Views' }) do
        TABS.each do |key, label|
          current = key == tab
          a(href: page_path(@history.step, tab: key), class: ['tabs__tab', ('tabs__tab--current' if current)],
            aria: { current: current ? 'page' : nil }) { label }
        end
      end
    end

    # The main tab: the file, if there is one, and what a person can do now.
    def render_tab(kind)
      div(class: ['record-page__body', ('record-page__body--no-preview' unless preview?)]) do
        render_preview if preview?
        div(class: 'record-page__panel') do
          if live?
            render_panel(kind)
          else
            fieldset(class: 'record-page__frozen', disabled: true) { render_panel(kind) }
          end
        end
      end
    end

    # Whether there's a file to show beside the panel.
    def preview? = true

    def render_time_travel
      message = @history.messages[@history.current_step - 1]
      p(class: 'time-travel', role: 'status') do
        span do
          plain "Step #{@history.current_step} of #{@history.messages.size}: as it was after "
          code { message.type.delete_prefix("#{self.class.machine_class.message_prefix}.") }
        end
        a(href: page_path) { 'Back to live' }
      end
    end

    def can?(command) = @machine.available_commands.include?(command)

    # ---- The file ----

    # The thumbnail of +file+ (a DocumentState: file_ref, filename,
    # content_type) opens it in a dialog. The dialog is left alone when the
    # page re-renders (data-ignore-morph), so an update doesn't close it.
    def render_file_preview(file)
      file_id = file&.file_ref
      figure(class: 'preview') do
        if file_id
          button(type: 'button', class: 'preview__thumb', aria: { label: "Open #{file.filename}" },
                 data: { 'on:click' => "document.getElementById('file-dialog').showModal()" }) do
            img(src: "/files/#{file_id}/thumbnail", alt: "Preview of #{file.filename}", loading: 'lazy')
          end
          figcaption { 'Open full size' }
          render_dialog(file)
        else
          div(class: 'preview__placeholder') { 'Uploading' }
        end
      end
    end

    def render_dialog(file)
      file_id = file.file_ref
      dialog(id: 'file-dialog', class: 'file-dialog', data: { 'ignore-morph' => true, 'on:click' => 'evt.target === el && el.close()' }) do
        form(method: 'dialog', class: 'file-dialog__bar') do
          span(class: 'file-dialog__name') { file.filename }
          a(href: "/files/#{file_id}", target: '_blank', rel: 'noopener') { 'Open in a new tab' }
          button(type: 'submit', aria: { label: 'Close' }) { '×' }
        end
        if file.content_type == 'application/pdf'
          # Fitted to the width (a PDF open parameter): the viewer's default
          # fits the whole page, which leaves a receipt tiny. No page thumbnails
          # sidebar either: receipts are a page or two.
          iframe(src: "/files/#{file_id}#view=FitH&navpanes=0", title: file.filename, class: 'file-dialog__file')
        else
          img(src: "/files/#{file_id}", alt: file.filename, class: 'file-dialog__file')
        end
      end
    end

    # ---- What a person can do now ----

    # What the panel is about, and whose move it is: called out for
    # attention when it's a person's.
    def lead(text) = p(class: ['panel-lead', ('callout--attention' if @status&.stage == :yours)]) { text }

    # +actions+ ([command class, text, payload fields] each) that can be
    # sent now, +primary+ first, in the call-to-action colour. A block
    # renders what goes before them all. +final+ for the row that ends a
    # review, set apart from the steps above it.
    def render_actions(actions, primary: nil, final: false)
      div(class: ['actions', ('actions--final' if final)]) do
        yield if block_given?
        actions.partition { |klass, *| klass == primary }.flatten(1)
               .each { |klass, text, fields| action(klass, text, primary: klass == primary, **(fields || {})) }
      end
    end

    # +selected+ marks the button for what's already chosen (aria-pressed);
    # +suggested+ for what's proposed but not chosen yet, which choosing
    # confirms; +disabled+ when choosing it again would change nothing.
    # +fields+ is the payload, with the record's id unless it names one.
    def action(klass, text, primary: false, selected: nil, suggested: false, disabled: false, **fields)
      fields = { self.class.key => @id }.merge(fields) unless fields.key?(:document_id) || fields.key?(:expense_id)
      command klass, key: fields.except(self.class.key).values.join('-').then { it.empty? ? 'cmd' : it } do |f|
        f.payload_fields(**fields)
        button(type: :submit, disabled:,
               class: ['button', ('button--primary' if (primary || suggested) && !selected), ('button--selected' if selected),
                       ('button--suggested' if suggested)],
               aria: { pressed: selected.nil? ? nil : selected.to_s }) { text }
      end
    end

    def field(name, &)
      label(class: 'review-form__field') do
        span { name }
        yield
      end
    end
  end
end
