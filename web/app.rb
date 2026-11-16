# frozen_string_literal: true

# The web app: which commands browsers may send, how they're handled, and pages.
# config.ru runs it.
class App < Sidereal::App
  layout UI::Layout

  dep :file_store, :thumbnails, 'expenses.filing_country' => 'filing_country'

  E = Expenses::Expense

  # One channel per expense, so a submission's page only hears about its
  # own. The home page listens to all of them (expenses.>).
  channel_name do |msg|
    expense_id = msg.payload.respond_to?(:expense_id) && msg.payload.expense_id
    expense_id ? "expenses.#{expense_id}" : 'system'
  end

  # Runs during the request, while Rack's Tempfile still exists: store the
  # file, then hand the backend its id, and send the browser to the new
  # submission's page to watch it scan. Only UploadDocument is dispatched —
  # the web command carries the Tempfile and is never stored.
  handle Commands::UploadFile do |cmd|
    file = cmd.payload.file
    document = Expenses::Upload.store(file_store, filename: file.filename, content_type: file.type, io: file.tempfile,
                                                  filing_country:)
    dispatch document
    browser.redirect "/submissions/#{document.payload.expense_id}"
  end

  # What a person does with a submission. The machine refuses any its
  # current state doesn't accept.
  handle E::SaveExpense, E::Rescan, E::EnterManually, E::DiscardDocument, E::VoidExpense,
         E::Filed::ConfirmVatTreatment

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
