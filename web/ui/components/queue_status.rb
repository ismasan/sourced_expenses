# frozen_string_literal: true

module UI
  module Components
    # A work queue (a Queuer) at a glance: a box per slot, striped while in
    # use, how many are waiting their turn, and how many have been done. By
    # its id, a page can re-render just this when the queue changes (its
    # Changed signal).
    #
    #   render QueueStatus.for(Expenses::ScanQueue, title: 'Scanning', noun: 'scan')
    class QueueStatus < Phlex::HTML
      # More slots than this show as one bar, filled to the share in use.
      MAX_BOXES = 12

      # @param queue [Class<Queuer>]
      # @param title [String] what the queue does
      # @param noun [String] one item of its work, for the counts
      def self.for(queue, title:, noun:) = new(queue.status, title:, noun:)

      # @param status [Queuer::Status]
      def initialize(status, title:, noun:)
        @status = status
        @title = title
        @noun = noun
      end

      def id = "queue-#{@status.queue_name}"

      def view_template
        section(id:, class: ['queue-status', ('queue-status--busy' unless @status.idle?)],
                aria: { labelledby: "#{id}-title" }) do
          h2(id: "#{id}-title", class: 'queue-status__title') { @title }
          render_slots
          p(class: 'queue-status__summary') do
            plain summary
            plain " · #{count(@status.released_total)} done" if @status.released_total.positive?
          end
        end
      end

      private

      def render_slots
        label = "#{@status.in_flight} of #{@status.capacity} slots in use"
        if @status.capacity > MAX_BOXES
          share = (100.0 * [@status.in_flight, @status.capacity].min / @status.capacity).round
          div(class: 'queue-status__bar', role: 'img', aria: { label: }) do
            span(class: 'queue-status__fill', style: "width: #{share}%")
          end
        else
          ol(class: 'queue-status__slots', role: 'img', aria: { label: }) do
            @status.capacity.times do |i|
              li(class: ['queue-status__slot', ('queue-status__slot--busy' if i < @status.in_flight)])
            end
          end
        end
      end

      def summary
        return "Idle: room for #{count(@status.capacity)} at once" if @status.idle?

        running = "#{@status.in_flight} of #{@status.capacity} running"
        @status.queued.zero? ? running : "#{running} · #{@status.queued} waiting"
      end

      def count(n) = n == 1 ? "1 #{@noun}" : "#{n} #{@noun}s"
    end
  end
end
