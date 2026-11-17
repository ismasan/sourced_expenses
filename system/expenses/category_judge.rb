# frozen_string_literal: true

require 'ruby_llm'

module Expenses
  # Which of CATEGORIES an expense goes under, as a RubyLLM judgment: one
  # choice, answered with a probability for every category rather than
  # generated text. Expenses::LLM#categorize asks it about what the scan
  # read or the person filed, never the document itself.
  #
  #   CategoryJudge.judge({ description: 'Uber - Trip', vendor: 'Uber', ... }).category.choice # => 'travel'
  class CategoryJudge < RubyLLM::Judge
    choice :category,
           'Which bookkeeping category should this business expense be booked under? ' \
           'Judge by what was bought, from the supplier and description. ' \
           'Choose general only when no other category fits.',
           CATEGORIES.transform_values { |(label, description)| "#{label}: #{description}" }
  end
end
