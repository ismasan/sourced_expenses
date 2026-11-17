# frozen_string_literal: true

module UI
  # Page layout: Sidereal's BasicLayout styles, plus this app's own stylesheet
  # in web/public/css/app.css.
  class Layout < Sidereal::Components::BasicLayout
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
          style { raw safe(STYLES) }
          link(rel: 'stylesheet', href: '/css/app.css?26')
        end

        body do
          render Components::TopNav.new(context.request.path_info, query: search_query)
          div(class: 'page') do
            render page
          end
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
