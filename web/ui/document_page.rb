# frozen_string_literal: true

module UI
  # One uploaded document: its preview, where its scan is, and what a person
  # can do with it now. Once read (or filled in by hand), its expense has
  # the review: this page links to it.
  #
  # The upload form links here straight away, so the page often renders
  # before the machine has decided UploadDocument: it shows "Uploading…" and
  # reloads as the document's events arrive on its channel.
  class DocumentPage < RecordPage
    MACHINE = Expenses::Document
    ID_TYPE = Types::DocumentID
    NOUN = :document

    path '/documents/:document_id'
    # Anything else in the path is a 400.
    query_schema document_id: Types::DocumentID

    D = Expenses::Document
    E = Expenses::Expense

    # Every event the document's machine evolves, its states included, and
    # its expense's, which has the document's id: drafted, filed.
    on D, E

    # Forms must be for commands the document accepts as it is now.
    with_machine { @machine }

    TRACK = %w[Upload Scan Expense].freeze
    TRACK_AT = { 'uploading' => 0, 'scanning' => 1, 'rejected' => 1, 'failed' => 1, 'read' => 2 }.freeze

    def initialize(id, history)
      super
      expense = MachineHistory.load(E, id)
      @expense = expense.machine if expense.any?
    end

    private

    # Its expense's channel too, which is under the same id.
    def own_channels = [*super, "expenses.#{channel_segment(@id)}"]

    def back_link = ['Home', '/']

    def render_title = plain(@doc.filename || 'New upload')

    def render_preview = render_file_preview(@doc.file_ref && @doc)

    def render_panel(kind)
      case kind
      when 'uploading' then lead('Storing the file. Nothing for you to do yet.')
      when 'scanning'
        lead('Reading the document. Nothing for you to do yet: its expense is drafted when it’s done.')
        actions
      when 'rejected'
        lead('This doesn’t look like a receipt or invoice. Fill it in by hand if it is one, or discard it.')
        blockquote(class: 'reason') { @doc.verification&.dig(:explanation) }
        render_expense
        actions(primary: D::EnterManually)
      when 'failed'
        lead('The scan stopped before it finished. Scan it again, or fill it in by hand.')
        blockquote(class: 'reason') { @doc.failure&.dig(:reason) }
        render_expense
        actions(primary: D::Rescan)
      when 'read'
        render_expense
        actions
      else lead('This upload was discarded.')
      end
    end

    # Its expense, where it is, and a link to it. Nothing while it's being
    # drafted: none yet.
    def render_expense
      unless @expense
        lead('Read. Drafting its expense…') if @status.kind == 'read'
        return
      end

      status = Status.for(@expense.machine.paths)
      p(class: 'panel-lead') do
        plain(paths.include?('entered_by_hand') ? 'Its expense, to fill in by hand: ' : 'Its expense: ')
        a(href: "/expenses/#{@id}") { @expense.context.draft[:description] || 'New expense' }
      end
      div(class: 'actions') do
        render Components::StatusBadge.new(status, size: :small)
        a(href: "/expenses/#{@id}", class: 'button button--primary') { 'Review it' } if status.stage == :yours
      end
    end

    # Fill in by hand, rescan, discard: whichever the document accepts now.
    # A rescan replaces its expense's draft, so not once it's filed. Filling
    # in by hand drafts it empty, so only while it has none: once it has one
    # (a rescan that failed), its draft is kept, to fill in on its page.
    def actions(primary: nil)
      list = [[D::EnterManually, 'Fill in by hand'], [D::Rescan, 'Scan again'], [D::DiscardDocument, 'Discard']]
             .select { |klass, _| can?(klass) }
      list.reject! { |klass, _| klass == D::EnterManually } if @expense
      list.reject! { |klass, _| klass == D::Rescan } if expense_settled?
      render_actions(list, primary:)
    end

    # Its expense is past review: filed, voided or discarded.
    def expense_settled? = @expense && !@expense.available_commands.include?(E::DiscardExpense)
  end
end
