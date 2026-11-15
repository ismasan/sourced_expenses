# frozen_string_literal: true

module UI
  # The home page: upload a receipt or invoice, and watch every upload go
  # through its scan.
  class WelcomePage < Sidereal::Page
    path '/'

    # Only the list follows the backend: the upload form would otherwise
    # reload the whole page on everything an upload leads to.
    disable_causal_reactivity!

    on Expenses::Submissions::Projected do |_evt|
      browser.patch_elements UI::Components::SubmissionList.new(UI::WelcomePage.submissions)
    end

    # Every expense's channel: the list follows them all.
    def channel_name = 'expenses.>'

    def self.submissions = Expenses::Submissions.recent(Sidereal.config['db'])

    def self.load(_params, _ctx) = new(submissions)

    def initialize(submissions = [])
      @submissions = submissions
    end

    def view_template
      div(id: 'welcome-page', class: 'welcome') do
        header(class: 'masthead') do
          div do
            h1(class: 'masthead__title') { 'Expenses' }
            p(class: 'masthead__lead') { 'Drop in a receipt. It’s read for you, and you check it before it’s filed.' }
          end
          a(class: 'masthead__link', href: '/sourced') { 'Sourced dashboard' }
        end
        render UI::Components::UploadForm.new
        render UI::Components::SubmissionList.new(@submissions)
      end
    end
  end
end
