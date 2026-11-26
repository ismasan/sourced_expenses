# frozen_string_literal: true

require 'securerandom'

# The web app: which commands browsers may send, how they're handled, and pages.
# config.ru runs it.
class App < Sidereal::App
  layout UI::Layout

  dep :file_store, :thumbnails, :freeagent

  E = Expenses::Expense
  D = Documents::Document
  I = Integrations::FreeAgentImport

  # Ids are the digest of the bytes, so a file never changes under its URL.
  IMMUTABLE = 'private, max-age=31536000, immutable'

  # A session per browser, so the commands it sends carry its session, and
  # the notices they cause (a retry, a failure) show only on its pages, not
  # on every page following the expense. The cookie's key is derived from
  # Sidereal's master secret (SIDEREAL_SECRET, or else storage/secret.txt),
  # read on each request, once the components are built.
  session secret: -> { Sidereal.secrets.derive('session') }

  # One channel per expense and one per document, so each one's page only
  # hears about its own (and an expense's page its document's), and one per
  # work queue (its events), under system., which every page listens to
  # (UI::Page::SYSTEM_CHANNELS) for the scan queue's bar. A message with an
  # expense's id and its document's (DraftExpenseFromDocument,
  # DocumentAttached) is the expense's.
  channel_name do |msg|
    payload = msg.payload
    queue_name = payload.respond_to?(:queue_name) && payload.queue_name
    import_id = payload.respond_to?(:import_id) && payload.import_id
    expense_id = payload.respond_to?(:expense_id) && payload.expense_id
    document_id = payload.respond_to?(:document_id) && payload.document_id
    if queue_name then "system.#{queue_name}"
    elsif import_id then "freeagent_imports.#{import_id}"
    elsif expense_id then "expenses.#{expense_id}"
    elsif document_id then "documents.#{document_id}"
    else 'system'
    end
  end

  # What a person does with a document or an expense. The machine refuses
  # any its current state doesn't accept.
  handle D::Rescan, D::EnterManually, D::DiscardDocument,
         I::SyncFreeAgent,
         E::SaveExpense, E::DiscardExpense, E::VoidExpense, E::ConfirmVatTreatment, E::ChooseCategory

  # The components the pages render, for their stylesheets and the commands
  # they handle (UploadForm's UploadFile, NewExpenseForm's NewExpense). The layout's stylesheets come
  # first, then these and the pages', in the order of these lines: the
  # order of the cascade. Attention's go last, to win over the rest.
  component UI::Components::TopNav
  component UI::Components::Search
  component UI::Components::SearchPreview
  component UI::Components::StatusBadge
  component UI::Components::UploadForm
  component UI::Components::UploadReport
  component UI::Components::NewExpenseForm
  component UI::Components::QueueBar
  component UI::Components::BeingRead
  component UI::Components::ExpenseRows
  component UI::Components::IntegrationsLayout
  component UI::Components::FreeAgentDisconnect
  component UI::Components::HistoryFeed
  component UI::Components::LedgerTotal
  component UI::Components::MonthChart

  page UI::WelcomePage
  page UI::ExpensesPage
  page UI::NewExpensePage
  page UI::ExpensePage
  page UI::ExpenseDiagramPage
  page UI::DocumentPage
  page UI::DocumentDiagramPage
  page UI::IntegrationsPage
  page UI::FreeAgentPage

  component UI::Attention

  # Time travel: an expense's or a document's page as it was after +step+
  # messages of its history. Static, so nothing live replaces it. The
  # history feed links here.
  get '/expenses/:expense_id/at/:step' do |expense_id:, step:|
    render_in_place(at(UI::ExpensePage, expense_id, step))
  end

  get '/expenses/:expense_id/diagram/at/:step' do |expense_id:, step:|
    render_in_place(at(UI::ExpenseDiagramPage, expense_id, step))
  end

  get '/documents/:document_id/at/:step' do |document_id:, step:|
    render_in_place(at(UI::DocumentPage, document_id, step))
  end

  get '/documents/:document_id/diagram/at/:step' do |document_id:, step:|
    render_in_place(at(UI::DocumentDiagramPage, document_id, step))
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

  # Every day at 8am, the server's local time: an import of what changed on
  # FreeAgent since the last one, the same SyncFreeAgent the FreeAgent
  # page's button and `bin/sid expenses import freeagent` send. The
  # scheduler appends it to the store itself, for Integrations::FreeAgentImport
  # to take. Not connected yet, the run fails, saying so on the FreeAgent
  # page. Schedules tick on the leader process alone, so it's one import
  # however many processes run; a morning the app isn't running is skipped,
  # not made up.
  schedule I::SCHEDULE do
    at '0 8 * * *', I::SyncFreeAgent, import_id: I::ACCOUNT
  end

  # Where FreeAgent sends a person back to once they've let this app read
  # their account: FREEAGENT_REDIRECT_URI, or this app's callback at
  # +base_url+. It must be one the app has in FreeAgent's Developer Dashboard.
  def self.freeagent_redirect_uri(base_url)
    Sidereal.config['freeagent.redirect_uri'] || "#{base_url}/integrations/freeagent/callback"
  end

  # Connecting FreeAgent: off to FreeAgent to let this app read the account,
  # with a state only this browser's session knows, to check on the way back.
  get '/integrations/freeagent/connect' do
    halt 404, 'FreeAgent isn’t set up' unless freeagent.configured?

    state = SecureRandom.hex(16)
    session['freeagent_state'] = state
    redirect freeagent.authorize_url(redirect_uri: App.freeagent_redirect_uri(request.base_url), state:), status: 303
  end

  # Back from FreeAgent: the code it sent traded for tokens (kept by
  # Integrations::FreeAgent::Tokens), then the FreeAgent page, saying why not if it failed.
  get '/integrations/freeagent/callback' do
    params = request.params
    expected = session.delete('freeagent_state')
    error = if params['error'] then "FreeAgent didn’t connect: #{params['error_description'] || params['error']}"
            elsif expected.nil? || !Rack::Utils.secure_compare(expected, params['state'].to_s)
              'That connection wasn’t started here: connect again'
            end
    unless error
      begin
        freeagent.connect(code: params['code'].to_s, redirect_uri: App.freeagent_redirect_uri(request.base_url))
      rescue Integrations::FreeAgent::Error => e
        error = e.message
      end
    end
    path = UI::FreeAgentPage.path
    redirect error ? "#{path}?#{URI.encode_www_form(error:)}" : path, status: 303
  end

  # An uploaded file as it was uploaded, for the document and expense pages' modal.
  get '/files/:file_id' do |file_id:|
    file = stored(file_id)
    send_file file.path, filename: file.filename, cache_control: IMMUTABLE
  end

  # Its preview, for their thumbnail.
  get '/files/:file_id/thumbnail' do |file_id:|
    send_file thumbnails.path_for(stored(file_id)), cache_control: IMMUTABLE
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

  private def at(page, id, step)
    step = Integer(step, 10, exception: false)
    step && page.at(id, step)
  end

  private def stored(file_id)
    file_store.read(file_id)
  rescue FileStore::NotFound
    halt 404, 'Not found'
  end
end
