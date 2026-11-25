# frozen_string_literal: true

module Expenses
  # Suggests each expense's category (CATEGORIES) once it's drafted or
  # entered, for the person reviewing it to confirm or change. It asks the
  # model (LLM#categorize, a CategoryJudge judgment) about its figures (what
  # a scan read, or a person entered), never a document itself, and reports back
  # with Expense::SuggestCategory, or Expense::FailCategorization with a
  # reason a person can read. Never once a person has chosen one, which
  # every filed expense has, nor for a draft with no description.
  #
  # A consumer group of its own, so a model call never holds up the
  # machine. Started on an existing store, it catches up on every drafted
  # expense still in review. Failures aren't evolved, so a reset (`bin/sid sourced groups reset
  # expenses.categorizer`) tries those again, and any never categorized,
  # without asking again about any it has a suggestion for. What it can
  # expect to go wrong (LLM::Error) becomes the failure; anything else is a
  # bug and raises, which stops its group.
  class Categorizer < Sourced::Decider
    partition_by expense_id: Types::ExpenseID

    dep :llm

    E = Expense

    # Not the whole Document: what the model is told about the expense,
    # the description it last suggested a category for, and whether a
    # person has chosen one.
    context { { expense: {}, suggested_for: nil, chosen: false } }

    # Its figures, drafted, redrafted or entered: what the model is told.
    FIGURES = proc do |state, evt|
      p = evt.payload.to_h
      total = p[:net_price_cents] && (p[:net_price_cents] + p[:tax_amount_cents].to_i)
      state[:expense] = {
        description: p[:description], vendor: p[:vendor], tax_description: p[:tax_description],
        supplier_country: p[:supplier_country_code], total: total && format('%.2f %s', total / 100.0, p[:currency])
      }
    end
    evolve E::ExpenseDrafted, &FIGURES
    evolve E::ExpenseRedrafted, &FIGURES
    evolve E::ExpenseEntered, &FIGURES

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

    reaction E::ExpenseDrafted => E::SuggestCategory | E::FailCategorization | nil do |state, drafted|
      categorize(drafted, state)
    end

    # Its document read again: a new description to suggest for.
    reaction E::ExpenseRedrafted => E::SuggestCategory | E::FailCategorization | nil do |state, redrafted|
      categorize(redrafted, state)
    end

    reaction E::ExpenseEntered => E::SuggestCategory | E::FailCategorization | nil do |state, entered|
      categorize(entered, state)
    end

    private

    # Nothing if the expense has moved on since +trigger+ (filed, redrafted,
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
