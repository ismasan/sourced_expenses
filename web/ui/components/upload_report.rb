# frozen_string_literal: true

module UI
  module Components
    # How the files of the last upload went, one line each, under the
    # upload form: emptied as an upload starts, then a line appended for
    # each file. The UploadFile handler appends one for each it takes (Item:
    # uploaded, or uploaded before, linking to its expense); the form's
    # script one for each it skips without sending (the wrong type, too
    # big), with the same classes.
    class UploadReport < Phlex::HTML
      ID = 'upload-report'

      # One file's line.
      class Item < Phlex::HTML
        # @param filename [String]
        # @param outcome [Symbol] :uploaded, or :already (uploaded before)
        # @param expense_id [String] its expense
        def initialize(filename, outcome, expense_id)
          @filename = filename
          @outcome = outcome
          @expense_id = expense_id
        end

        def view_template
          li(class: "upload-report__item upload-report__item--#{@outcome}") do
            strong { @filename }
            if @outcome == :already
              plain ' was uploaded before: '
              a(href: "/submissions/#{@expense_id}") { 'see it' }
            else
              plain ' uploaded, being read'
            end
          end
        end
      end

      def view_template
        ul(id: ID, class: 'upload-report', role: 'status', aria: { live: 'polite' })
      end
    end
  end
end
