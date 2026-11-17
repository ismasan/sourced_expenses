# frozen_string_literal: true

module Expenses
  # Suggests each expense's category (CATEGORIES): once its scan is done,
  # and again whenever it's filed with a description it hasn't suggested
  # one for (an expense filled in by hand, or a corrected description). It
  # asks the model (LLM#categorize, a CategoryJudge judgment) about what
  # the scan read and the person filed, never the document itself, and
  # reports back with Expense::SuggestCategory, or
  # Expense::FailCategorization with a reason a person can read. Never once
  # a person has chosen one.
  #
  # A consumer group of its own, so a model call never holds up the
  # machine. Started on an existing store, it catches up on every expense
  # in review or filed: categorizing existing expenses is the backfill.
  # Failures aren't evolved, so a reset (`bin/sid sourced groups reset
  # expenses.categorizer`) tries those again, and any never categorized,
  # without asking again about any it has a suggestion for. What it can
  # expect to go wrong (LLM::Error) becomes the failure; anything else is a
  # bug and raises, which stops its group.
  class Categorizer < Sourced::Decider
    partition_by expense_id: Types::ExpenseID

    dep :llm

    E = Expense
    S = Expense::Scanning

    # Not the whole Document: what the model is told about the expense,
    # the description it last suggested a category for, and whether a
    # person has chosen one.
    context { { expense: {}, suggested_for: nil, chosen: false } }

    evolve E::DocumentUploaded do |state, evt|
      state[:expense][:filename] = evt.payload.filename
    end

    evolve S::ExtractionRecorded do |state, evt|
      state[:expense].merge!(
        description: evt.payload.description, vendor: evt.payload.vendor_name,
        tax_description: evt.payload.tax_description, supplier_country: evt.payload.supplier_country_code,
        total: evt.payload.total_amount && format('%.2f %s', evt.payload.total_amount, evt.payload.currency)
      )
    end

    evolve S::TextCleaned do |state, evt|
      state[:expense][:description] = evt.payload.description
    end

    # What the person filed is what the expense is. The vendor stays, from
    # the scan: the form has none.
    evolve E::ExpenseFiled do |state, evt|
      filed = evt.payload
      state[:expense].merge!(
        description: filed.description, tax_description: filed.tax_description,
        supplier_country: filed.supplier_country_code,
        total: format('%.2f %s', (filed.net_price_cents + filed.tax_amount_cents) / 100.0, filed.currency)
      )
    end

    evolve E::CategorySuggested do |state, evt|
      state[:suggested_for] = evt.payload.description
    end

    evolve E::CategoryChosen do |state, _evt|
      state[:chosen] = true
    end

    # Evolved so they count as moving on for projection.current?.
    evolve(E::ExpenseVoided) { |_state, _evt| nil }
    evolve(E::Discarded) { |_state, _evt| nil }
    evolve(E::ScanRequested) { |_state, _evt| nil }

    reaction S::Scanned => E::SuggestCategory | E::FailCategorization | nil do |state, scanned|
      categorize(scanned, state)
    end

    reaction E::ExpenseFiled => E::SuggestCategory | E::FailCategorization | nil do |state, filed|
      categorize(filed, state)
    end

    private

    # Nothing if the expense has moved on since +trigger+ (filed, rescanned,
    # voided, discarded: an old event a new group is catching up on), if a
    # person has chosen a category, or if there's a suggestion for this
    # description already.
    def categorize(trigger, state)
      return unless projection.current?(trigger)
      return if state[:chosen]

      expense = state[:expense]
      description = expense[:description]
      return if description.nil? || description.strip.empty? || state[:suggested_for] == description

      expense_id = trigger.payload.expense_id
      dispatch(E::SuggestCategory, expense_id:, description:, **llm.categorize(**expense))
    rescue LLM::Error => e
      dispatch(E::FailCategorization, expense_id:, description:, reason: e.message)
    end
  end
end
