# frozen_string_literal: true

module UI
  # The home page: upload a receipt or invoice, and the uploads waiting for
  # a person. Every upload is on the expense list (ExpensesPage).
  class WelcomePage < Sidereal::Page
    path '/'

    # Only the list follows the backend: the upload form would otherwise
    # reload the whole page on everything an upload leads to.
    disable_causal_reactivity!

    on Expenses::Submissions::Projected do |_evt|
      browser.patch_elements UI::Components::NeedsYou.new(*UI::WelcomePage.needs_you)
    end

    on Expenses::UsdLedger::Projected do |_evt|
      browser.patch_elements UI::Components::MonthTotal.current
    end

    # Every expense's channel: the list follows them all.
    def channel_name = 'expenses.>'

    # The latest of the uploads waiting for a person, and how many there are.
    def self.needs_you
      Expenses::Submissions.page(Sidereal.config['db'], states: Expenses::Submissions::NEEDS_YOU, per_page: 50)
    end

    def self.load(_params, _ctx) = new(*needs_you)

    def initialize(rows = [], total = 0)
      @rows = rows
      @total = total
    end

    def view_template
      div(id: 'welcome-page', class: 'welcome') do
        header(class: 'masthead') do
          div do
            h1(class: 'masthead__title') { 'Expenses' }
            p(class: 'masthead__lead') { 'Drop in a receipt. It’s read for you, and you check it before it’s filed.' }
          end
          render UI::Components::MonthTotal.current
        end
        render UI::Components::UploadForm.new
        render UI::Components::NeedsYou.new(@rows, @total)
      end
    end
  end
end
