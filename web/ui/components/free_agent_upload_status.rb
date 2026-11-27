# frozen_string_literal: true

module UI
  module Components
    # Where an expense filed here is on FreeAgent (FreeAgent::Upload,
    # whose state follows what the expense records), on its page, after
    # FreeAgent's logo: uploading, there (with a link), why it isn't (and a button
    # to try again), deleted there. Nothing for one it never uploaded.
    class FreeAgentUploadStatus < Sidereal::Components::BaseComponent
      U = FreeAgent::Upload

      file 'ui/components/freeagent.svg', path: 'freeagent.svg'
      css <<~CSS
        .freeagent-status__logo { width: 1.1em; height: 1.1em; margin-right: 0.4em; vertical-align: -0.2em; }
      CSS

      # @param expense_id [String]
      # @param upload [Sourced::Machine::Snapshot] U.load(expense_id:)
      def initialize(expense_id, upload)
        @expense_id = expense_id
        @state = upload.value
        @run = upload.context
      end

      def view_template
        return unless @state.is_a?(Class) # never uploaded: still initial

        p(class: 'filed__note freeagent-status') do
          img(class: 'freeagent-status__logo', src: asset_url('ui/components/freeagent.svg'), alt: 'FreeAgent',
              width: 16, height: 16)
          case @state
          when U::Uploading then plain 'Uploading to FreeAgent…'
          when U::Uploaded
            plain 'On FreeAgent too, kept up to date with corrections here.'
            if @run[:attached] then plain " Its file, #{@run[:attached]}, is attached there."
            elsif @run[:attachment_problem] then plain " Without its file: #{@run[:attachment_problem]}."
            end
            if @run[:external_url]
              plain ' '
              a(href: @run[:external_url], target: '_blank', rel: 'noopener') { 'Open in FreeAgent' }
            end
          when U::Failed then plain ['Not uploaded to FreeAgent', @run.dig(:failure, :reason)].compact.join(': ')
          when U::Deleting then plain 'Deleting it on FreeAgent…'
          when U::Deleted then plain 'Deleted on FreeAgent too.'
          when U::NotDeleted then plain ['Still on FreeAgent', @run.dig(:failure, :reason)].compact.join(': ')
          end
        end
        case @state
        when U::Failed then retry_button(U::RetryUpload, 'Upload it again')
        when U::NotDeleted then retry_button(U::RetryDelete, 'Delete it there again')
        end
      end

      private

      def retry_button(klass, label)
        command klass, class: 'actions' do |f|
          f.payload_fields(expense_id: @expense_id)
          button(type: :submit, class: 'button') { label }
        end
      end
    end
  end
end
