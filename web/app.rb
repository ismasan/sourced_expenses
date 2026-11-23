# frozen_string_literal: true

# The web app: which commands browsers may send, how they're handled, and pages.
# config.ru runs it.
class App < Sidereal::App
  layout UI::Layout

  dep :file_store, :thumbnails, 'expenses.filing_country' => 'filing_country'

  E = Expenses::Expense

  # A session per browser, so the commands it sends carry its session, and
  # the notices they cause (a retry, a failure) show only on its pages, not
  # on every page following the expense. The cookie's key is derived from
  # Sidereal's master secret (SIDEREAL_SECRET, or else storage/secret.txt),
  # read on each request, once the components are built.
  session secret: -> { Sidereal.secrets.derive('session') }

  # One channel per expense, so a submission's page only hears about its
  # own, and one per work queue (its events), under system., which every
  # page listens to (UI::Page::SYSTEM_CHANNELS) for the scan queue's bar.
  channel_name do |msg|
    queue_name = msg.payload.respond_to?(:queue_name) && msg.payload.queue_name
    expense_id = msg.payload.respond_to?(:expense_id) && msg.payload.expense_id
    if queue_name then "system.#{queue_name}"
    elsif expense_id then "expenses.#{expense_id}"
    else 'system'
    end
  end

  # One file, of the one or many the upload form sends one at a time.
  # Runs during the request, while Rack's Tempfile still exists: store the
  # file, then hand the backend its id. Only UploadDocument is dispatched —
  # the web command carries the Tempfile and is never stored. A file
  # uploaded before is that expense already: nothing dispatched. The
  # browser stays on the page: a line for the file is added to its report
  # (UploadReport), and the home page's lists follow the new expense.
  handle Commands::UploadFile do |cmd|
    file = cmd.payload.file
    document = Expenses::Upload.store(file_store, filename: file.filename, content_type: file.type, io: file.tempfile,
                                                  filing_country:)
    expense_id = document.payload.expense_id
    already = Expenses::Upload.uploaded?(expense_id)
    dispatch document unless already
    browser.patch_elements UI::Components::UploadReport::Item.new(file.filename, already ? :already : :uploaded, expense_id),
                           selector: "##{UI::Components::UploadReport::ID}", mode: 'append'
  end

  # What a person does with a submission. The machine refuses any its
  # current state doesn't accept.
  handle E::SaveExpense, E::Rescan, E::EnterManually, E::DiscardDocument, E::VoidExpense,
         E::ConfirmVatTreatment, E::ChooseCategory

  page UI::WelcomePage
  page UI::ExpensesPage
  page UI::SubmissionPage
  page UI::SubmissionDiagramPage

  # Time travel: a submission's page as it was after +step+ messages of its
  # history. Static, so nothing live replaces it. The history feed links here.
  get '/submissions/:expense_id/at/:step' do |expense_id:, step:|
    step = Integer(step, 10, exception: false)
    render_in_place(step && UI::SubmissionPage.at(expense_id, step))
  end

  get '/submissions/:expense_id/diagram/at/:step' do |expense_id:, step:|
    step = Integer(step, 10, exception: false)
    render_in_place(step && UI::SubmissionDiagramPage.at(expense_id, step))
  end

  # The search box's preview of what's typed (UI::Components::Search),
  # patched into its pane. Anything but a Datastar request gets the list
  # of every match.
  get '/search' do
    query = request.params['q'].to_s.strip
    redirect UI::ExpensesPage.path_for(search: (query unless query.empty?)), status: 303 unless browser.sse?

    browser.stream(heartbeat: false) do |sse|
      sse.patch_elements UI::Components::SearchPreview.for(query)
    end
  end

  # An uploaded file as it was uploaded, for the submission page's modal.
  get '/files/:file_id' do |file_id:|
    file = stored(file_id)
    send_file file.path, filename: file.filename
  end

  # Its preview, for the submission page's thumbnail.
  get '/files/:file_id/thumbnail' do |file_id:|
    send_file thumbnails.path_for(stored(file_id))
  rescue Thumbnails::Error
    halt 404, 'No preview'
  end

  # A Datastar request (a step link in the history feed) gets the page
  # patched in place and its URL pushed onto the browser's history; any
  # other gets the whole page.
  private def render_in_place(page)
    halt 404, 'Not found' unless page
    return component(page) unless browser.sse?

    path = request.path
    browser.stream(heartbeat: false) do |sse|
      sse.patch_elements page
      sse.execute_script "history.pushState({}, '', #{path.to_json})"
    end
  end

  private def stored(file_id)
    file_store.read(file_id)
  rescue FileStore::NotFound
    halt 404, 'Not found'
  end

  # Ids are the digest of the bytes, so a file never changes under its URL.
  private def send_file(path, filename: nil)
    headers = {
      'content-type' => Rack::Mime.mime_type(File.extname(path), 'application/octet-stream'),
      'cache-control' => 'private, max-age=31536000, immutable',
      'x-content-type-options' => 'nosniff'
    }
    headers['content-disposition'] = %(inline; filename="#{filename.gsub(/[^\w.\- ]/, '_')}") if filename
    # Set, not added: Router#headers appends, which would keep the default text/html.
    headers.each { |name, value| response.set_header(name, value) }
    halt 200, File.binread(path)
  end
end
