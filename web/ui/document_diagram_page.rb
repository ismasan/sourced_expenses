# frozen_string_literal: true

module UI
  # A document's Diagram tab (DiagramTab).
  class DocumentDiagramPage < DocumentPage
    include DiagramTab

    path '/documents/:document_id/diagram'
  end
end
