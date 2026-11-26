# frozen_string_literal: true

module UI
  # The home page: upload receipts and invoices, the documents being read
  # (BeingRead), and what's waiting for a person (NeedsYou: expenses to
  # review, documents that couldn't be read), all live, so an upload is
  # followed here until its expense is ready to review. Every expense is on
  # the expense list (ExpensesPage). How many documents are scanning and
  # waiting to is the scan queue's bar, along the bottom of every page
  # (QueueBar).
  class WelcomePage < Page
    stylesheet 'ui/welcome_page.css', path: 'welcome_page.css'

    path '/'

    # Only the list follows the backend: the upload form would otherwise
    # reload the whole page on everything an upload leads to.
    disable_causal_reactivity!

    on Documents::DocumentList::Projected do |_evt|
      browser.patch_elements UI::Components::BeingRead.load
      browser.patch_elements UI::Components::NeedsYou.load
    end

    on Expenses::ExpenseList::Projected do |_evt|
      browser.patch_elements UI::Components::NeedsYou.load
    end

    on Expenses::Ledger::Projected do |_evt|
      browser.patch_elements UI::Components::LedgerTotal.current
    end

    # Every document's and expense's channel: the lists follow them all.
    def channel_names = ['documents.>', 'expenses.>', *SYSTEM_CHANNELS]

    def self.load(_params, _ctx) = new(UI::Components::NeedsYou.load)

    def initialize(needs_you = UI::Components::NeedsYou.new)
      @needs_you = needs_you
    end

    def view_template
      div(id: 'welcome-page', class: 'welcome') do
        header(class: 'masthead') do
          div do
            h1(class: 'masthead__title') { 'Expenses' }
            p(class: 'masthead__lead') do
              plain 'Drop in a receipt. It’s read for you, and you check it before it’s filed. Or '
              a(href: NewExpensePage.path) { 'add an expense by hand' }
              plain '.'
            end
          end
          render UI::Components::LedgerTotal.current
        end
        render UI::Components::UploadForm.new
        render UI::Components::BeingRead.load
        render @needs_you
      end
    end
  end
end
