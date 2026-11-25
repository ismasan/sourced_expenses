# frozen_string_literal: true

module UI
  module Components
    # The home page's documents still being scanned, newest first, each with
    # the step it's on, above those waiting for a person (NeedsYou). Once
    # read, each one's expense is there. Re-rendered by its id whenever the
    # read model commits; with none, an empty element to patch.
    class BeingRead < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/being_read.css', path: 'being_read.css'

      ID = 'being-read'

      # The latest of them, and how many there are.
      def self.load(db = Sidereal.config['db'])
        new(*Expenses::DocumentList.page(db, states: %w[scanning], per_page: 50))
      end

      # @param rows [Array<Expenses::DocumentList::Row>] the latest of them
      # @param total [Integer] how many there are in all
      def initialize(rows, total)
        @rows = rows
        @total = total
      end

      def view_template
        if @rows.empty?
          div(id: ID)
          return
        end

        section(id: ID, class: 'submissions submissions--being-read', aria: { labelledby: "#{ID}-title" }) do
          h2(id: "#{ID}-title", class: 'submissions__title') do
            plain 'Being read'
            span(class: 'submissions__count') { @total.to_s }
          end
          render DocumentRows.new(@rows)
        end
      end
    end
  end
end
