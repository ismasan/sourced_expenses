# frozen_string_literal: true

module UI
  # Where an expense is, as a person reads it, from the machine's active
  # paths (Expenses::Submissions keeps them; a loaded machine has
  # machine.paths). Shared by the list and the submission page.
  #
  # Every status belongs to a stage, and the stage is what the colours mean:
  #   working  the scan has it: nothing to do but wait   (blue, moving)
  #   yours    it's waiting for a person: review, VAT    (yellow, like the buttons)
  #   problem  the scan stopped or rejected it: decide   (red)
  #   done     filed                                     (green)
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
      'uploading' => :working, 'scanning' => :working,
      'reviewing' => :yours, 'vat_review' => :yours,
      'rejected' => :problem, 'failed' => :problem,
      'filed' => :done, 'closed' => :closed
    }.freeze

    # @param paths [Array<String>]
    # @return [Info]
    def self.for(paths)
      label, kind = label_and_kind(paths)
      Info.new(label:, kind:, stage: STAGES.fetch(kind))
    end

    def self.label_and_kind(paths)
      step = SCAN_STEPS.keys.find { paths.include?(it) }
      return ["#{SCAN_STEPS[step]}…", 'scanning'] if step
      return ['Scanning…', 'scanning'] if paths.include?('scanning')
      return ['Ready to review', 'reviewing'] if paths.include?('reviewing')
      return ['Not a receipt', 'rejected'] if paths.include?('rejected')
      return ['Scan failed', 'failed'] if paths.include?('scan_failed')
      return ['Check the VAT', 'vat_review'] if paths.include?('filed.vat_needs_review')
      return ['Filed, VAT confirmed', 'filed'] if paths.include?('filed.vat_confirmed')
      return ['Filed', 'filed'] if paths.include?('filed')
      return ['Discarded', 'closed'] if paths.include?('discarded')
      return ['Voided', 'closed'] if paths.include?('voided')

      ['Uploading…', 'uploading']
    end
    private_class_method :label_and_kind
  end
end
