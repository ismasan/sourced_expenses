# frozen_string_literal: true

require 'ruby_llm'

module Expenses
  # Which category an expense goes under, as a RubyLLM judgment: one
  # choice, answered with a probability for every category rather than
  # generated text. The categories are an input, { key => what goes in it }:
  # the baseline's and every other one expenses have had (CategoryList).
  # Expenses::LLM#categorize asks it about what the scan read or the person
  # filed, never the document itself.
  #
  #   CategoryJudge.judge({ description: 'Uber - Trip', vendor: 'Uber', ... }, categories:).category.choice # => 'travel'
  class CategoryJudge < RubyLLM::Judge
    inputs :categories

    choice :category,
           'Which bookkeeping category should this business expense be booked under? ' \
           'Judge by what was bought, from the supplier and description. ' \
           'Choose sundries only when no other category fits.',
           -> { categories }
  end

  # The categories CategoryJudge chooses among, from CategoryList's choices:
  # a baseline one with what goes in it, another by its name alone.
  def self.judged_categories(choices)
    choices.to_h { [it.key, it.description ? "#{it.label}: #{it.description}" : it.label] }
  end
end
