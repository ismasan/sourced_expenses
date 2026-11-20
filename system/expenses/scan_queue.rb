# frozen_string_literal: true

module Expenses
  # How many expenses are scanned at once: each scan makes several model
  # calls, so this caps the calls in flight. An expense enters Queued on
  # upload or rescan, which enqueues it; it gets a slot here, which starts its
  # scan (StartScan); and leaving Scanning (or Queued, discarded before its
  # turn) releases it. The scan's timeout starts with the scan, not the wait.
  #
  # At most `expenses.max_scans` in flight (MAX_SCANS, see
  # config/components/scan_queue.rb).
  class ScanQueue < Queuer
    queue 'expenses.scan_queue', name: 'scans'

    dep 'expenses.max_scans' => 'max_scans'

    def capacity = max_scans

    def start(item_id) = Expense::StartScan.new(payload: { expense_id: item_id })
  end
end
