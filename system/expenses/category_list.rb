# frozen_string_literal: true

module Expenses
  # Every category an expense has had, in the `categories` table: suggested
  # by the model, chosen by a person, or brought by an import (a source's
  # own, such as FreeAgent's "Use of home", with its name there). Together
  # with the baseline (CATEGORIES) it's what's offered: the expense page's
  # list, the expense list's filters, and the model's choices
  # (Categorizer). A category stays once seen, whatever then happens to its
  # expenses.
  #
  #   CategoryList.all(db)     # => [Choice, ...] the baseline's, then the rest by name
  #   CategoryList.label(key)  # => "Use of home", or nil
  class CategoryList < Sourced::Projector::EventSourced
    partition_by expense_id: Types::ExpenseID

    dep :db

    # A category to choose: +description+ is the baseline's, nil for others.
    Choice = ::Data.define(:key, :label, :description)

    # The baseline, then every other category seen, by name.
    # @return [Array<Choice>]
    def self.all(db)
      baseline = CATEGORIES.map { |key, (label, description)| Choice.new(key:, label:, description:) }
      others = db[:categories].exclude(key: CATEGORIES.keys).all
                              .map { Choice.new(key: it[:key], label: it[:label] || Expenses.category_label(it[:key]), description: nil) }
      baseline + others.sort_by { it.label.downcase }
    end

    # The name +key+ came with, or nil: read from the table once, and again
    # only for a key it didn't have, so a page's labels make one query at most.
    def self.label(key)
      labels = (@labels ||= load_labels)
      return labels[key] if labels.key?(key)

      (@labels = load_labels)[key]
    end

    def self.load_labels = Sidereal.config['db'][:categories].exclude(label: nil).to_h { [it[:key], it[:label]] }

    # The group's offsets were rewound (`bin/sid sourced groups reset
    # expenses.category_list`): every row goes, and it builds them again.
    def self.on_reset
      Sidereal.config['db'][:categories].delete
      @labels = nil
    end
    private_class_method :load_labels

    E = Expense

    # The categories its expense has had: key => [name, source], either nil.
    context { {} }

    IMPORTED = proc do |seen, evt|
      p = evt.payload
      seen[p.category] = [p.source_category, p.source] if p.category
    end
    evolve E::ExpenseImported, &IMPORTED
    evolve E::ImportedExpenseChanged, &IMPORTED

    evolve E::CategorySuggested do |seen, evt|
      seen[evt.payload.category] ||= [nil, nil]
    end

    evolve E::CategoryChosen do |seen, evt|
      seen[evt.payload.category] ||= [nil, nil]
    end

    # A category already seen keeps its name, unless it had none.
    sync do |context:, **|
      rows = db[:categories]
      context.each do |key, (label, source)|
        existing = rows.where(key:).first
        if existing.nil?
          rows.insert(key:, label:, source:, first_seen_at: Time.now)
        elsif existing[:label].nil? && label
          rows.where(key:).update(label:, source:)
        end
      end
    end
  end
end
