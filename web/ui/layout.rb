# frozen_string_literal: true

module UI
  # Page layout, styled only by the app's stylesheets, which head links. This
  # one's (layout.css) are the shared rules: the reset, the colours and other
  # variables, links, buttons and fields. Each component and page brings its
  # own, in the order App installs them. Every page has the scan queue's bar
  # along its bottom while the queue is busy (Components::QueueBar, kept live
  # by UI::Page).
  class Layout < Sidereal::Components::Layout
    stylesheet 'ui/layout.css', path: 'layout.css'

    FONTS = 'https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:ital,wght@0,400..900;1,400..900&display=swap'

    def view_template
      doctype

      html(lang: 'en') do
        head do
          meta(charset: 'utf-8')
          meta(name: 'viewport', content: 'width=device-width, initial-scale=1.0')
          title { 'Sourced Expenses' }
          link(rel: 'preconnect', href: 'https://fonts.googleapis.com')
          link(rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true)
          link(rel: 'stylesheet', href: FONTS)
        end

        body do
          render Components::TopNav.new(context.request.path_info, query: search_query)
          div(class: 'page') do
            render page
          end
          # Live over the page's stream (UI::Page).
          render Components::QueueBar.scans
        end
      end
    end

    private

    # What the list is searched for, to keep in the box: only on the list.
    def search_query
      request = context.request
      request.path_info == ExpensesPage.path ? request.params['q'].to_s.strip : nil
    rescue Rack::QueryParser::ParamsTooDeepError, Rack::QueryParser::InvalidParameterError
      nil
    end
  end
end
