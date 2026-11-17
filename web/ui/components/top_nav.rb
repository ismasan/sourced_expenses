# frozen_string_literal: true

module UI
  module Components
    # The bar along the top of every page: the app's name, home, the search
    # box (Search), and the links in LINKS. Stuck to the top as the page scrolls. On a narrow
    # screen the links fold into a menu the button opens; _menu is a local
    # signal, never sent to the server.
    class TopNav < Sidereal::Components::BaseComponent
      LINKS = [
        ['All expenses', '/expenses'],
        ['Sourced dashboard', '/sourced']
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
              LINKS.each do |text, href|
                li do
                  a(href:, class: 'topnav__link', aria: { current: current?(href) ? 'page' : nil }) { text }
                end
              end
            end
          end
        end
      end

      private

      def current?(href) = @current_path == href || @current_path.start_with?("#{href}/")
    end
  end
end
