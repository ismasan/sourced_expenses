# frozen_string_literal: true

module UI
  module Components
    # The bar along the top of every page: the app's name, home, the search
    # box (Search), and the links in LINKS. Stuck to the top as the page scrolls. On a narrow
    # screen the links fold into a menu the button opens; _menu is a local
    # signal, never sent to the server.
    class TopNav < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/top_nav.css', path: 'top_nav.css'

      LINKS = [
        ['All expenses', '/expenses'],
        ['New expense', '/expenses/new'],
        ['Integrations', '/integrations'],
        ['Sourced dashboard', '/sourced', :cog]
      ].freeze

      # Feather's settings cog, for a link shown as an icon: its text is for
      # screen readers and the narrow menu.
      COG = [
        'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
        'M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 ' \
        '1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06' \
        'a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 ' \
        '2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06' \
        'a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 ' \
        '1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9' \
        'a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z'
      ].freeze

      # @param current_path [String] the page's path, to mark its link
      # @param query [String, nil] what the list is searched for, to show in the box
      def initialize(current_path, query: nil)
        @current_path = current_path
        @query = query
      end

      def view_template
        header(class: 'topnav', data: { 'signals:_menu' => 'false', 'class:topnav--open' => '$_menu' }) do
          nav(class: 'topnav__bar', aria: { label: 'Main' }) do
            a(class: 'topnav__brand', href: '/', aria: { current: @current_path == '/' ? 'page' : nil }) { 'Expenses' }
            render Search.new(@query)

            button(type: 'button', class: 'topnav__toggle', aria: { controls: 'topnav-links', expanded: 'false' },
                   data: { 'on:click' => '$_menu = !$_menu', 'attr:aria-expanded' => 'String($_menu)' }) do
              span(class: 'topnav__toggle-icon', aria: { hidden: 'true' })
              span(class: 'topnav__toggle-label') { 'Menu' }
            end

            ul(id: 'topnav-links', class: 'topnav__links') do
              LINKS.each do |text, href, icon|
                li do
                  a(href:, class: ['topnav__link', ('topnav__link--icon' if icon)], title: (text if icon),
                    aria: { current: current?(href) ? 'page' : nil }) do
                    if icon
                      cog
                      span(class: 'topnav__link-label') { text }
                    else
                      plain text
                    end
                  end
                end
              end
            end
          end
        end
      end

      private

      def cog
        svg(class: 'topnav__icon', viewbox: '0 0 24 24', width: 22, height: 22, fill: 'none', stroke: 'currentColor',
            stroke_width: 2, stroke_linecap: 'round', stroke_linejoin: 'round', aria_hidden: 'true') do |s|
          COG.each { s.path(d: it) }
        end
      end

      def current?(href) = @current_path == href || @current_path.start_with?("#{href}/")
    end
  end
end
