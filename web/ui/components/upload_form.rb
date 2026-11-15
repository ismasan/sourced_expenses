# frozen_string_literal: true

module UI
  module Components
    # Pick a receipt or invoice and upload it, or drop it anywhere on the page.
    # The UploadFile handler redirects to the new submission.
    #
    # The drop is handled in the browser with Datastar alone: the dropped file
    # goes into the form's file input and the form is submitted, so it's the
    # same multipart @post as choosing a file and clicking Upload.
    class UploadForm < Sidereal::Components::BaseComponent
      # The page-wide drag events, on the window. _drags counts dragenter
      # minus dragleave, since both fire for every element the pointer
      # crosses; it's above 0 while a file is over the page. Signals starting
      # with _ are local: never sent to the server.
      DROP_EVENTS = {
        'signals:_drags' => '0',
        'on:dragenter__window' => "evt.dataTransfer.types.includes('Files') && $_drags++",
        'on:dragleave__window' => '$_drags > 0 && $_drags--',
        # Preventing dragover's default is what makes the page a drop target.
        'on:dragover__window__prevent' => "evt.dataTransfer.dropEffect = 'copy'",
        # Only the first file: the form uploads one at a time. Going through a
        # DataTransfer is the only way to build a FileList for the input.
        # The browser doesn't check +accept+ on a drop; the handler checks the
        # type and reports it in the field's errors.
        'on:drop__window__prevent' => <<~JS.gsub(/\s*\n\s*/, ' ').strip
          $_drags = 0;
          evt.dataTransfer.files.length && !$fetching && ((dt) => {
            dt.items.add(evt.dataTransfer.files[0]);
            const input = el.querySelector('input[type=file]');
            input.files = dt.files;
            input.form.requestSubmit();
          })(new DataTransfer())
        JS
      }.freeze

      def view_template
        section(class: 'upload', aria: { label: 'Upload' }, data: DROP_EVENTS.merge('class:upload--dragging' => '$_drags > 0')) do
          render Sidereal::Components::Command.new(Commands::UploadFile, enctype: 'multipart/form-data', class: 'upload__form') do |f|
            p(class: 'upload__prompt') do
              span(data: { show: '!$fetching' }) do
                span(class: 'upload__drop') { 'Drop a receipt or invoice anywhere on this page' }
                span(class: 'upload__touch') { 'Add a receipt or invoice' }
              end
              span(data: { show: '!!$fetching' }, style: 'display: none') { 'Uploading…' }
            end
            p(class: 'upload__formats') do
              plain 'PDF, JPEG, PNG or WebP, up to 20 MB.'
              span(class: 'upload__drop') { ' Or pick one:' }
            end
            div(class: 'upload__pick') do
              f.file_field :file, accept: Commands::ACCEPTED_UPLOAD_TYPES.join(','), required: true,
                                  'aria-label': 'Receipt or invoice'
              # !! because the indicator signal starts as "", and data-attr only
              # drops an attribute for false or null.
              button(type: :submit, class: 'button button--primary', data: { 'attr:disabled' => '!!$fetching' }) { 'Upload' }
            end
          end

          # Covers the page while a file is dragged over it.
          div(class: 'upload__overlay', aria: { hidden: 'true' }, data: { show: '$_drags > 0' }, style: 'display: none') do
            p { 'Drop to upload' }
          end
        end
      end
    end
  end
end
