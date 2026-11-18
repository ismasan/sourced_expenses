# frozen_string_literal: true

module Expenses
  # Suggests each expense's category (CATEGORIES) once its scan is done, for
  # the person reviewing it to confirm or change. It asks the model
  # (LLM#categorize, a CategoryJudge judgment) about what the scan read,
  # never the document itself, and reports back with
  # Expense::SuggestCategory, or Expense::FailCategorization with a reason a
  # person can read. Never once a person has chosen one, which every filed
  # expense has: one filled in by hand gets no suggestion.
  #
  # A consumer group of its own, so a model call never holds up the
  # machine. Started on an existing store, it catches up on every scanned
  # expense still in review. Failures aren't evolved, so a reset (`bin/sid sourced groups reset
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

    evolve E::CategorySuggested do |state, evt|
      state[:suggested_for] = evt.payload.description
    end

    evolve E::CategoryChosen do |state, _evt|
      state[:chosen] = true
    end

    # Evolved so they count as moving on for projection.current?.
    evolve(E::ExpenseFiled) { |_state, _evt| nil }
    evolve(E::ExpenseVoided) { |_state, _evt| nil }
    evolve(E::Discarded) { |_state, _evt| nil }
    evolve(E::ScanRequested) { |_state, _evt| nil }

    reaction S::Scanned => E::SuggestCategory | E::FailCategorization | nil do |state, scanned|
      categorize(scanned, state)
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
