# frozen_string_literal: true

module UI
  module Components
    # A status, coloured by its stage (see UI::Status).
    class StatusBadge < Phlex::HTML
      # @param status [UI::Status::Info]
      def initialize(status, size: nil)
        @status = status
        @size = size
      end

      def view_template
        span(class: ['badge', "badge--#{@status.stage}", ("badge--#{@size}" if @size)]) { @status.label }
      end
    end
  end
end
