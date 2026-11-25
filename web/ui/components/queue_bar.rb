# frozen_string_literal: true

module UI
  module Components
    # A work queue (a WorkQueue) as a segmented bar along the bottom of every
    # page, one segment per document: the queue's capacity first, a segment
    # per slot, striped while a document is in it and empty while free; then,
    # past a gap, a segment per document waiting its turn. Hidden while the
    # queue is idle. The layout renders it, and UI::Page keeps it live over
    # the page's stream (the queue's events are on system.<queue name>).
    #
    # Rendered because the queue changed (+changed+, the stream's patches on
    # its events), an idle queue has just finished: the bar shows it's all
    # done, then slides down and fades out after a few seconds (CSS, on the
    # --done class). An idle queue otherwise (a page load, a reconnect) is
    # just hidden. Patches morph the bar, so new work mid-fade brings it back.
    #
    #   render QueueBar.scans
    class QueueBar < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/queue_bar.css', path: 'queue_bar.css'

      # More segments than this, and the waiting ones past it show as "+N".
      MAX_SEGMENTS = 48

      # The expenses' scan queue.
      # @param changed [Boolean] rendered because the queue just changed
      def self.scans(changed: false)
        new(Expenses::Expense::ScanQueue.status, title: 'Scanning', noun: 'document', changed:)
      end

      # @param status [WorkQueue::Status]
      # @param title [String] what the queue does
      # @param noun [String] one item of its work, for the counts
      # @param changed [Boolean] rendered because the queue just changed: idle,
      #   it has just finished
      def initialize(status, title:, noun:, changed: false)
        @status = status
        @title = title
        @noun = noun
        @done = changed && status.idle?
      end

      def id = "queue-#{@status.queue_name}"

      def view_template
        section(id:, class: ['queue-bar', ('queue-bar--done' if @done)], hidden: @status.idle? && !@done,
                aria: { label: "#{@title} queue" }) do
          div(class: 'queue-bar__inner') do
            p(class: 'queue-bar__summary', role: 'status') do
              strong(class: 'queue-bar__title') { @title }
              @done ? span(class: 'queue-bar__done') { ' ✓ All done' } : plain(" #{summary}")
            end
            render_track
          end
        end
      end

      private

      def render_track
        slots = [@status.capacity, MAX_SEGMENTS].min
        running = [@status.in_flight, slots].min
        waiting = [@status.queued, MAX_SEGMENTS - slots].min
        hidden = @status.queued - waiting

        div(class: 'queue-bar__track', aria: { hidden: true }) do
          # Each group grows by its count, so every segment is as wide.
          div(class: 'queue-bar__slots', style: "flex-grow: #{slots}") do
            if @done
              slots.times { segment('done', 'Done') }
            else
              running.times { segment('running', "#{@title}: a #{@noun} in this slot") }
              (slots - running).times { segment('free', 'A free slot') }
            end
          end
          if waiting.positive?
            div(class: 'queue-bar__waiting', style: "flex-grow: #{waiting}") do
              waiting.times { segment('waiting', "A #{@noun} waiting for a slot") }
            end
          end
          span(class: 'queue-bar__more') { "+#{hidden}" } if hidden.positive?
        end
      end

      def segment(kind, title) = span(class: ['queue-bar__segment', "queue-bar__segment--#{kind}"], title:)

      def summary
        running = "#{@status.in_flight} of #{@status.capacity} slots in use"
        @status.queued.zero? ? running : "#{running} · #{count(@status.queued)} waiting"
      end

      def count(n) = n == 1 ? "1 #{@noun}" : "#{n} #{@noun}s"
    end
  end
end
