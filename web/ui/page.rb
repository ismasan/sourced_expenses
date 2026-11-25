# frozen_string_literal: true

module UI
  # The app's pages: each has the scan queue's bar along its bottom
  # (Components::QueueBar, which the layout renders), live over the page's
  # own stream. A page names its channels with #channel_names, its own and
  # SYSTEM_CHANNELS, where App routes the work queues' events
  # (system.<queue name>).
  #
  #   def channel_names = ['expenses.>', *SYSTEM_CHANNELS]
  class Page < Sidereal::Page
    SYSTEM_CHANNELS = %w[system.>].freeze

    # A page that takes no updates of its own still follows the queue.
    def channel_names = SYSTEM_CHANNELS

    # Each of the scan queue's events re-renders its bar, as changed: so the
    # queue going idle shows as done, and the bar leaves.
    on WorkQueue do |evt|
      next unless evt.payload.queue_name == Expenses::Expense::ScanQueue.name

      browser.patch_elements Components::QueueBar.scans(changed: true)
    end

    # The bar too, as it is now, when the stream (re)connects: the page
    # renders again, but the bar is the layout's.
    def self.stream(channel, sse, params, ctx, **)
      sse.patch_elements Components::QueueBar.scans
      super
    end
  end
end
