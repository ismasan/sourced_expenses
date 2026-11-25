# frozen_string_literal: true

module UI
  # A RecordPage's Diagram tab: its machine's statechart, with the states it
  # is in lit and the moves it can make next highlighted. Live, or at a step
  # of its history, like the main tab.
  # Its stylesheet is RecordPage's, so it's registered once.
  module DiagramTab
    def tab = :diagram

    private

    def render_tab(_kind)
      section(class: 'machine-view', aria: { label: 'Statechart' }) do
        render Sourced::UI::Components::Statechart.new(@machine.to_h, title: "#{self.class.machine_class.name.split('::').last} statechart")
        render Sourced::UI::Components::StatechartLegend.new
      end
    end
  end
end
