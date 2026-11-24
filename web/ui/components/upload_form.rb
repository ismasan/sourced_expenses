# frozen_string_literal: true

module UI
  module Components
    # Pick receipts and invoices and upload them, or drop them anywhere on
    # the page: one or many at once. The page stays put: each file's line
    # shows in the report under the form (UploadReport), and the home
    # page's lists show the new expenses as they're read.
    #
    # Each file is its own Commands::UploadFile, sent one after another
    # (UPLOAD): a file put into the form's file input alone, and posted as
    # Datastar posts any command form. A file the scan can't take (the
    # wrong type, too big) is skipped before it's sent, with a line saying
    # why; the command checks again, should one get past.
    #
    # The drop is handled in the browser with Datastar alone: the dropped
    # files go into the form's file input and the form is submitted, as
    # choosing files and clicking Upload does.
    class UploadForm < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/upload_form.css', path: 'upload_form.css'

      # _uploading is how many files the upload is sending, _sent how many
      # of them are in: an upload is on while _uploading is above 0.
      SIGNALS = { _drags: 0, _uploading: 0, _sent: 0 }.freeze

      # The page-wide drag events, on the window. _drags counts dragenter
      # minus dragleave, since both fire for every element the pointer
      # crosses; it's above 0 while a file is over the page. Signals starting
      # with _ are local: never sent to the server.
      DROP_EVENTS = {
        'on:dragenter__window' => "evt.dataTransfer.types.includes('Files') && $_drags++",
        'on:dragleave__window' => '$_drags > 0 && $_drags--',
        # Preventing dragover's default is what makes the page a drop target.
        'on:dragover__window__prevent' => "evt.dataTransfer.dropEffect = 'copy'",
        # Every file dropped. Going through a DataTransfer is the only way to
        # build a FileList for the input.
        'on:drop__window__prevent' => <<~JS.gsub(/\s*\n\s*/, ' ').strip
          $_drags = 0;
          evt.dataTransfer.files.length && !$_uploading && ((dt) => {
            [...evt.dataTransfer.files].forEach(f => dt.items.add(f));
            const input = el.querySelector('input[type=file]');
            input.files = dt.files;
            input.form.requestSubmit();
          })(new DataTransfer())
        JS
      }.freeze

      # The upload, as window.uploadFiles(form, signals), which the form's
      # submit calls (UPLOAD): the report emptied, a line for each file
      # skipped (as the command would refuse it: Expenses::Upload's checks),
      # then each of the rest alone in the input, posted, and waited for
      # before the next, so they go one at a time. The form is cleared after.
      #
      # A script asset is an ES module, and in production every script is
      # bundled into one, so it declares nothing at the top level: only the
      # global the form calls. Signals and @post exist only in Datastar's
      # expressions, so the submit passes them in as +signals+: busy() is
      # an upload on, start(n) starts one of n files, post() posts the form
      # (a promise that settles once its response has been handled), sent()
      # counts one in, and done() ends it.
      js <<~JS
        window.uploadFiles = async function (form, signals) {
          const input = form.querySelector('input[type=file]');
          const files = [...input.files];
          if (!files.length || signals.busy()) return;
          const report = document.getElementById('#{UploadReport::ID}');
          report.replaceChildren();
          const types = #{JSON.generate(Expenses::Upload::ACCEPTED_TYPES)};
          const problem = f => !types.includes(f.type) ? #{JSON.generate(Expenses::Upload::WRONG_TYPE)}
            : f.size > #{Expenses::Upload::MAX_BYTES} ? #{JSON.generate(Expenses::Upload::TOO_BIG)} : null;
          const sending = files.filter(f => {
            const why = problem(f);
            if (!why) return true;
            const li = document.createElement('li');
            li.className = 'upload-report__item upload-report__item--skipped';
            li.append(Object.assign(document.createElement('strong'), { textContent: f.name }), ' wasn’t uploaded: ' + why);
            report.append(li);
            return false;
          });
          signals.start(sending.length);
          try {
            for (const f of sending) {
              const one = new DataTransfer();
              one.items.add(f);
              input.files = one.files;
              await signals.post();
              signals.sent();
            }
          } finally {
            signals.done();
            form.reset();
          }
        };
      JS

      # The form's submit: the upload, with the signals and @post it uses.
      UPLOAD = <<~JS.gsub(/\s*\n\s*/, ' ').strip
        uploadFiles(el, {
          busy: () => $_uploading > 0,
          start: n => { $_sent = 0; $_uploading = n },
          post: () => @post('/commands', { contentType: 'form' }),
          sent: () => $_sent++,
          done: () => $_uploading = 0
        })
      JS

      def view_template
        section(class: 'upload', aria: { label: 'Upload' },
                data: DROP_EVENTS.merge('signals' => JSON.generate(SIGNALS), 'class:upload--dragging' => '$_drags > 0')) do
          # on: [] leaves the posting to UPLOAD, one file at a time, rather
          # than Sidereal's @post of the whole form on submit.
          render Sidereal::Components::Command.new(Commands::UploadFile, on: [], enctype: 'multipart/form-data',
                                                                         class: 'upload__form',
                                                                         data: { 'on:submit__prevent' => UPLOAD }) do |f|
            p(class: 'upload__prompt') do
              span(data: { show: '!$_uploading' }) do
                span(class: 'upload__drop') { 'Drop receipts or invoices anywhere on this page' }
                span(class: 'upload__touch') { 'Add receipts or invoices' }
              end
              span(data: { show: '$_uploading > 0', text: "'Uploading ' + ($_sent + 1) + ' of ' + $_uploading + '…'" },
                   style: 'display: none') { 'Uploading…' }
            end
            p(class: 'upload__formats') do
              plain 'PDF, JPEG, PNG or WebP, up to 20 MB each.'
              span(class: 'upload__drop') { ' Or pick them:' }
            end
            div(class: 'upload__pick') do
              # Not f.file_field: the same input, taking many files, which
              # UPLOAD sends one at a time as the command's one file.
              f.send(:with_errors, :file) do |id|
                input(id:, type: 'file', name: 'command[payload][file]', multiple: true, required: true,
                      accept: Expenses::Upload::ACCEPTED_TYPES.join(','), 'aria-label': 'Receipts or invoices')
              end
              # !! because data-attr only drops an attribute for false or null.
              button(type: :submit, class: 'button button--primary', data: { 'attr:disabled' => '!!$_uploading' }) { 'Upload' }
            end
            # While the files go up: no percentage, as fetch reports none:
            # the app's working stripes, until they're in.
            div(class: 'upload__progress', role: 'progressbar', aria: { label: 'Uploading' },
                data: { show: '$_uploading > 0' }, style: 'display: none')
          end

          render UploadReport.new

          # Covers the page while a file is dragged over it.
          div(class: 'upload__overlay', aria: { hidden: 'true' }, data: { show: '$_drags > 0' }, style: 'display: none') do
            p { 'Drop to upload' }
          end
        end
      end
    end
  end
end
