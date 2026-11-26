# frozen_string_literal: true

module UI
  # Where a document or an expense is, as a person reads it, from its
  # machine's active paths (Documents::DocumentList and ExpenseList keep
  # them; a loaded machine has machine.paths). Their states' names don't
  # overlap, but for discarded, which reads the same for both. Shared by the
  # lists and the pages.
  #
  # Every status belongs to a stage, and the stage is what the colours mean:
  #   working  the scan has it: nothing to do but wait   (blue, moving)
  #   yours    it's waiting for a person: review, file   (yellow, like the buttons)
  #   problem  the scan stopped or rejected it: decide   (red)
  #   done     read into an expense, or filed            (green)
  #   closed   discarded or voided                       (grey)
  module Status
    Info = Data.define(:label, :kind, :stage) do
      # The list's grouping: what needs a person first.
      def group
        case stage
        when :yours, :problem then :needs_you
        when :working then :in_progress
        else :done
        end
      end
    end

    # The scan's steps. The transient decisions show as the step they decide on.
    SCAN_STEPS = {
      'scanning.preparing' => 'Preparing the file',
      'scanning.extracting' => 'Reading the document',
      'scanning.checking_extraction' => 'Checking what was read',
      'scanning.verifying' => 'Checking it is a receipt',
      'scanning.checking_date' => 'Checking the date',
      'scanning.rechecking_date' => 'Double-checking the date',
      'scanning.cleaning' => 'Tidying up the text'
    }.freeze

    STAGES = {
      'uploading' => :working, 'scanning' => :working, 'drafting' => :working,
      'reviewing' => :yours, 'reviewed' => :yours,
      'rejected' => :problem, 'failed' => :problem,
      'read' => :done, 'filed' => :done, 'closed' => :closed
    }.freeze

    # @param paths [Array<String>]
    # @param machine [Symbol] :document or :expense: whose paths, for what
    #   none yet means (an upload being stored, or a draft being decided)
    # @return [Info]
    def self.for(paths, machine: :expense)
      label, kind = label_and_kind(paths, machine)
      Info.new(label:, kind:, stage: STAGES.fetch(kind))
    end

    def self.label_and_kind(paths, machine)
      step = SCAN_STEPS.keys.find { paths.include?(it) }
      return ["#{SCAN_STEPS[step]}…", 'scanning'] if step
      return ['Scanning…', 'scanning'] if paths.include?('scanning')
      return ['Waiting to be read…', 'scanning'] if paths.include?('queued')
      return ['Ready to review', 'reviewing'] if paths.include?('reviewing')
      return ['Ready to file', 'reviewed'] if paths.include?('reviewed')
      return ['Not a receipt', 'rejected'] if paths.include?('rejected')
      return ['Scan failed', 'failed'] if paths.include?('scan_failed')
      return ['Read', 'read'] if paths.include?('scanned')
      return ['Filled in by hand', 'read'] if paths.include?('entered_by_hand')
      return ['Filed', 'filed'] if paths.include?('filed')
      return ['Discarded', 'closed'] if paths.include?('discarded')
      return ['Voided', 'closed'] if paths.include?('voided')

      machine == :document ? ['Uploading…', 'uploading'] : ['Drafting…', 'drafting']
    end
    private_class_method :label_and_kind
  end
end
