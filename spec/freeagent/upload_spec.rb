# frozen_string_literal: true

require 'sourced/testing/rspec'

module FreeAgent
  class Upload
    RSpec.describe Upload do
      include Sourced::Testing::RSpec

      let(:store) { Sidereal.config['sourced.store'] }
      let(:expense_id) { SecureRandom.hex(16) }
      let(:travel_url) { 'https://api.freeagent.test/v2/categories/365' }

      # The one account's settings live in one partition: each example's go
      # when it's done.
      around do |example|
        Sidereal.config['db'].transaction(rollback: :always, auto_savepoint: true) { example.run }
      end

      before do
        FAKE_FREEAGENT.categories = {
          travel_url => FreeAgent::Client::Category.new(url: travel_url, nominal_code: '365', description: 'Travel')
        }
      end

      def ecmd(klass, **payload) = klass.new(payload: { expense_id:, **payload })
      def ucmd(klass, **payload) = ecmd(klass, **payload)

      def settings!(*commands)
        account = Settings::ACCOUNT
        given = @settings || []
        @settings = decided(Settings, { account: }, *commands.map { it.new(payload: { account: }) }, given:)
        store.append(@settings.drop(given.size))
      end

      def uploads_on! = settings!(Settings::TurnUploadsOn)

      def form(**overrides)
        { description: 'Train to Leeds', net_price_cents: 2000, tax_amount_cents: 400, currency: 'GBP',
          incurred_on: Date.new(2026, 11, 20), payment_reference: 'R-1', **overrides }
      end

      # The expense after +commands+, in the store, where the upload reads it.
      def expense!(*commands, given: [])
        decided(E, { expense_id: }, *commands, given:).tap { store.append(it.drop(given.size)) }
      end

      def entered(**overrides) = ecmd(E::EnterExpense, filing_country: 'GB', **form(**overrides))
      def filing(**overrides) = [ecmd(E::ChooseCategory, category: 'travel'), ecmd(E::ConfirmVatTreatment, treatment: 'domestic'),
                                 ecmd(E::SaveExpense, **form(**overrides))]
      def filed_here(**overrides) = expense!(entered(**overrides), *filing(**overrides))

      # What the machine appends and dispatches claiming +message+, given
      # +history+.
      def react(history, message)
        messages = nil
        history.reduce(with_reactor(Upload, expense_id:)) { |gwt, msg| gwt.given(msg) }
               .when(message).then { messages = it.messages }
        messages
      end

      # +history+ (the expense's and the upload's) after +messages+ (the
      # expense's), each claimed as it arrives, and the upload's entries run
      # and the commands they dispatch decided, as the runtime would, until
      # it settles (unless +settle+ is false).
      def feed(history, messages, settle: true)
        fed = messages.reduce(history) { |h, message| h + [message, *react(h, message)] }
        entering = fed.drop(history.size).reverse.find { it.class.name.start_with?(Upload.name) }
        settle && entering ? settle(fed, entering:) : fed
      end

      # +entering+: the state event whose entry runs, the last by default.
      # +entering+: the state event whose entry runs, the last by default.
      # What it dispatches to the expense is decided there and stored, and
      # the expense's events fed back, as they'd arrive.
      def settle(history, entering: history.last)
        return history unless [Uploading, Deleting, Failed, NotDeleted].any? { entering.is_a?(it) }

        # Its reports to the expense, not the timeouts scheduled for later.
        commands = react(history - [entering], entering).grep(Sourced::Command)
                                                        .reject { [TimeOutUpload, TimeOutDelete].include?(it.class) }
        commands.reduce(history) do |h, command|
          expense = h.select { it.class.name.start_with?("Expenses::Expense::") }
          recorded = decided(E, { expense_id: }, command, given: expense).drop(expense.size)
          store.append(recorded)
          feed(h, recorded)
        end
      end

      # The upload, decided on one of its own commands (a person's, or a
      # timeout), then settled.
      def own(history, command) = settle(decided(Upload, { expense_id: }, command, given: history))
      def recorded(history, klass) = history.grep(klass).select { it.payload.destination == 'freeagent' }

      # The upload after the expense's history, as it arrives.
      def uploaded(expense_history) = feed([], expense_history)
      def uploads(history) = history.grep(Upload::Uploading)

      def run(history) = Upload.new(expense_id:).tap { it.evolve(history) }
      def value(history) = run(history).machine.value

      it 'is a valid chart' do
        expect(Upload.to_h).to include(:states)
      end

      it 'creates an expense filed here on FreeAgent, keeping its url' do
        uploads_on!
        done = uploaded(filed_here)

        expect(value(done)).to eq(Uploaded)
        expect(FAKE_FREEAGENT.writes.size).to eq(1)
        kind, url, attributes = FAKE_FREEAGENT.writes.first
        expect(kind).to eq(:create)
        expect(attributes).to eq(user: FAKE_FREEAGENT.current_user_url, category: travel_url, dated_on: '2026-11-20',
                                 currency: 'GBP', description: 'Train to Leeds', gross_value: '-24.00',
                                 receipt_reference: 'R-1', ec_status: 'UK/Non-EC', sales_tax_rate: '20.0')
        uploaded = recorded(done, E::ExpenseUploaded)
        expect(uploaded.map { it.payload.external_id }).to eq([url.split('/').last])
        expect(uploaded.first.payload.external_url).to eq("https://example.freeagent.com/users/1/expenses/#{url.split('/').last}/edit")
        expect(store.read(E.history_selector.bind(expense_id:)).messages.grep(E::ExpenseUploaded).size).to eq(1)
      end

      it 'leaves alone what was filed while uploads were off, before they were turned on, or while disconnected' do
        expect(uploads(uploaded(filed_here))).to be_empty

        before_on = filed_here
        uploads_on!
        expect(uploads(uploaded(before_on))).to be_empty

        FAKE_FREEAGENT.connected = false
        expect(uploads(uploaded(filed_here))).to be_empty

        settings!(Settings::TurnUploadsOff)
        FAKE_FREEAGENT.connected = true
        expect(uploads(uploaded(filed_here))).to be_empty
        expect(FAKE_FREEAGENT.writes).to be_empty
      end

      it 'never uploads an expense imported from FreeAgent, even corrected here' do
        uploads_on!
        imported = expense!(ecmd(E::ImportExpense, source: 'freeagent', external_id: '123', filing_country: 'GB',
                                                   **form, supplier_country_code: nil, reverse_charge: false,
                                                   category: 'travel', source_category: 'Travel', vat_treatment: 'domestic'))
        corrected = expense!(ecmd(E::SaveExpense, **form(description: 'Train to York')), given: imported)

        expect(uploads(uploaded(imported))).to be_empty
        expect(uploads(uploaded(corrected))).to be_empty
        expect(FAKE_FREEAGENT.writes).to be_empty
      end

      # As the runtime reads it: from the store, through its history selector.
      it 'knows an imported expense from its history in the store' do
        expense!(ecmd(E::ImportExpense, source: 'freeagent', external_id: '124', filing_country: 'GB',
                                        **form, supplier_country_code: nil, reverse_charge: false,
                                        category: 'travel', source_category: 'Travel', vat_treatment: 'domestic'))

        expect(Upload.load(expense_id:).context[:imported]).to be(true)
      end

      # An expense drafted from a document whose file is +bytes+, filed.
      def filed_from_document(filename, content_type, bytes)
        file_ref = Sidereal.config['file_store'].put(filename, bytes)
        store.append([Documents::Document::DocumentUploaded.new(payload: { document_id: file_ref, filename:, content_type:,
                                                                           file_ref:, filing_country: 'GB' })])
        expense!(ecmd(E::DraftExpenseFromDocument, document_id: file_ref, filing_country: 'GB', **form), *filing)
      end

      it 'attaches its document’s file, once' do
        uploads_on!
        first = filed_from_document('train.pdf', 'application/pdf', '%PDF-1.4 train')
        done = uploaded(first)
        corrected = expense!(ecmd(E::SaveExpense, **form(description: 'Train to York')), given: first)
        done = feed(done, corrected.drop(first.size))

        (_, _, created), (_, _, updated) = FAKE_FREEAGENT.writes
        expect(created[:attachment]).to eq(data: Base64.strict_encode64('%PDF-1.4 train'), file_name: 'train.pdf',
                                           content_type: 'application/x-pdf')
        expect(updated).not_to have_key(:attachment)
        expect(recorded(done, E::ExpenseUploaded).map { it.payload.attachment }).to eq(['train.pdf', nil])
        expect(run(done).context[:attached]).to eq('train.pdf')
        expect(Sourced.load(E, expense_id:).first.context.upload('freeagent')[:attachment]).to eq('train.pdf')
      end

      it 'uploads without a file FreeAgent can’t take, saying why' do
        uploads_on!
        done = uploaded(filed_from_document('big.pdf', 'application/pdf', 'x' * 5_000_001))

        expect(value(done)).to eq(Uploaded)
        expect(FAKE_FREEAGENT.writes.first.last).not_to have_key(:attachment)
        expect(recorded(done, E::ExpenseUploaded).first.payload.attachment_problem).to match(/over 5 MB/)
        expect(run(done).context[:attachment_problem]).to match(/over 5 MB/)
      end

      it 'sends no attachment for an expense entered by hand' do
        uploads_on!
        uploaded(filed_here)
        expect(FAKE_FREEAGENT.writes.first.last).not_to have_key(:attachment)
      end

      it 'updates the same expense with a correction' do
        uploads_on!
        first = filed_here
        done = uploaded(first)
        corrected = expense!(ecmd(E::SaveExpense, **form(description: 'Train to York')), given: first)
        done = feed(done, corrected.drop(first.size))

        (_, url, _), (kind, updated, attributes) = FAKE_FREEAGENT.writes
        expect([kind, updated.split('/').last, attributes[:description]]).to eq([:update, url.split('/').last, 'Train to York'])
        expect(recorded(done, E::ExpenseUploaded).size).to eq(2)
        expect(value(done)).to eq(Uploaded)
      end

      it 'uploads again a correction filed while uploading' do
        uploads_on!
        first = filed_here
        uploading = feed([], first, settle: false)
        entering = uploads(uploading).last
        expect(entering).not_to be_nil
        corrected = expense!(ecmd(E::SaveExpense, **form(description: 'Train to York')), given: first)
        # The correction arrives before the upload's entry has run: it's
        # taken when the first upload is done.
        history = feed(uploading, corrected.drop(first.size), settle: false)
        expect(uploads(history).size).to eq(1)

        done = settle(history, entering:)

        expect(FAKE_FREEAGENT.writes.map(&:first)).to eq(%i[create update])
        expect(value(done)).to eq(Uploaded)
      end

      it 'says why FreeAgent didn’t take it, uploading it again when asked' do
        uploads_on!
        FAKE_FREEAGENT.write_error = FreeAgent::Error.new('FreeAgent refused it: Category is not valid')
        failed = uploaded(filed_here)

        expect(value(failed)).to eq(Failed)
        expect(run(failed).context[:failure]).to include(reason: 'FreeAgent refused it: Category is not valid', unsure: false)

        FAKE_FREEAGENT.write_error = nil
        expect(recorded(failed, E::ExpenseUploadFailed).map { it.payload.reason }).to eq(['FreeAgent refused it: Category is not valid'])
        done = own(failed, ucmd(RetryUpload))
        expect(value(done)).to eq(Uploaded)
        expect(run(done).context[:failure]).to be_nil
      end

      it 'says one it couldn’t reach FreeAgent to create may be there all the same' do
        uploads_on!
        FAKE_FREEAGENT.write_error = FreeAgent::Unreachable.new('FreeAgent could not be reached')
        failed = uploaded(filed_here)

        expect(run(failed).context[:failure]).to include(unsure: true, reason: /may have been created there all the same/)
      end

      it 'says why it couldn’t be mapped, writing nothing' do
        uploads_on!
        failed = uploaded(expense!(entered(currency: 'EUR'), *filing(currency: 'EUR')))

        expect(value(failed)).to eq(Failed)
        expect(run(failed).context[:failure][:reason]).to include('not the company’s currency')
        expect(FAKE_FREEAGENT.writes).to be_empty
      end

      it 'deletes it on FreeAgent when it’s voided here' do
        uploads_on!
        filed = filed_here
        done = uploaded(filed)
        voided = expense!(ecmd(E::VoidExpense, reason: 'Duplicate'), given: filed)
        done = feed(done, voided.drop(filed.size))

        id = recorded(done, E::ExpenseUploaded).first.payload.external_id
        expect(FAKE_FREEAGENT.writes.last).to eq([:delete, "/expenses/#{id}", nil])
        expect(recorded(done, E::ExpenseUploadDeleted).size).to eq(1)
        expect(value(done)).to eq(Deleted)
      end

      it 'records on the expense why a call timed out, unsure whether it was created' do
        uploads_on!
        uploading = feed([], filed_here, settle: false)
        failed = own(uploading, ucmd(TimeOutUpload))

        expect(value(failed)).to eq(Failed)
        expect(recorded(failed, E::ExpenseUploadFailed).map { [it.payload.reason, it.payload.unsure] })
          .to eq([[Upload::TIMED_OUT, true]])
      end

      it 'leaves alone a voided one it never uploaded' do
        filed = filed_here
        voided = expense!(ecmd(E::VoidExpense, reason: 'Duplicate'), given: filed)
        uploads_on!

        expect(feed([], voided).grep(Deleting)).to be_empty
      end

      it 'keeps the expenses it created, for the importer to leave out' do
        uploads_on!
        done = uploaded(filed_here)
        uploads = recorded(done, E::ExpenseUploaded)
        uploads.reduce(with_reactor(UploadList, expense_id:)) { |gwt, msg| gwt.given(msg) }.then! { nil }

        id = uploads.first.payload.external_id
        expect(UploadList.external_ids(Sidereal.config['db'])).to include(id)
      end
    end
  end
end
