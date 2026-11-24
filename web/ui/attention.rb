# frozen_string_literal: true

module UI
  # The attention look's stylesheet (attention.css): .attention and
  # .callout--attention, for anything waiting for a person. It renders
  # nothing. App installs it last, so its rules come after every other
  # stylesheet, and win over a component's own look at the same specificity.
  class Attention < Sidereal::Components::BaseComponent
    stylesheet 'ui/attention.css', path: 'attention.css'
  end
end
