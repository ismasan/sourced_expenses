# frozen_string_literal: true

require 'date'
require 'tmpdir'

module Documents
  # What each of Document::Scanning's waiting states asks for: the work
  # Expenses::Scanner does when a document enters one. Each step takes the
  # document's DocumentState and returns the payload of the step's Complete…
  # command, or raises Error with a reason fit to show a person.
  #
  # The decisions between the steps aren't here: they're the chart's, over
  # DocumentState.
  class ScanSteps
    Error = Class.new(StandardError)

    def initialize(llm:, file_store:)
      @llm = llm
      @file_store = file_store
    end

    # preparing: PDFs and small images go as they are; a larger image is
    # shrunk into a JPEG of its own, stored next to the original.
    def prepare(doc)
      file = read(doc.file_ref)
      return { processed_file_ref: file.id, downsized: false } if pdf?(doc) || Images.small_enough?(file.path)

      Dir.mktmpdir do |dir|
        shrunk = Images.shrink(file.path, File.join(dir, 'prepared.jpg'))
        name = "#{File.basename(doc.filename, '.*')}-prepared.jpg"
        { processed_file_ref: File.open(shrunk, 'rb') { @file_store.put(name, it) }, downsized: true }
      end
    rescue Images::Error => e
      raise Error, e.message
    end

    # extracting: the main read, against Prompts::EXTRACTION_SCHEMA.
    def extract(doc)
      today = spelled_out(doc.reference_date)
      answer = ask(
        instructions: Prompts::SYSTEM_PROMPT.gsub('%{today}', today),
        schema: Prompts::EXTRACTION_SCHEMA,
        message: Prompts::USER_PROMPT_TEMPLATE
          .gsub('%{document_type}', pdf?(doc) ? 'PDF document' : 'image')
          .gsub('%{today}', today),
        file: processed_path(doc)
      )
      answer.slice(*Document::Scanning::EXTRACTION.keys)
    end

    # verifying: told what looked wrong, is this a receipt at all?
    def verify(doc)
      message = <<~MSG
        I tried to extract expense data from this document but encountered issues:
        #{doc.extraction_errors.map { "- #{it}" }.join("\n")}

        Please examine the image and tell me: is this actually a receipt, invoice, or expense document?
      MSG
      answer = ask(
        instructions: Prompts::DOCUMENT_VERIFICATION_PROMPT,
        schema: Prompts::DOCUMENT_VERIFICATION_SCHEMA,
        message:, file: processed_path(doc)
      )
      answer.slice(:is_invoice_or_receipt, :explanation)
    end

    # rechecking_date: the date alone, with the first reading offered up as
    # suspect. Whether its answer replaces the first is DocumentState's call.
    def recheck_date(doc)
      previous = doc.extracted_date
      instructions = Prompts::DATE_RECHECK_PROMPT
                     .gsub('%{printed}', doc.extraction[:date_as_printed].to_s)
                     .gsub('%{previous_date}', previous.to_s)
                     .gsub('%{today}', spelled_out(doc.reference_date))
                     .gsub('%{distance}', distance(previous, doc.reference_date))
      answer = ask(
        instructions:, schema: Prompts::DATE_RECHECK_SCHEMA,
        message: 'Read the transaction date on this document again and report it.',
        file: processed_path(doc)
      )
      answer.slice(:date_as_printed, :candidates, :date, :reasoning)
            .merge(candidates: Array(answer[:candidates]).map { it.transform_keys(&:to_sym) })
    end

    # cleaning: mojibake out of the two free-text fields. Text only.
    def clean(doc)
      description = doc.extraction[:description]
      tax_description = doc.extraction[:tax_description]
      message = <<~MSG
        Document language: #{doc.extraction[:document_language] || 'en'}

        Please review these extracted text fields for OCR errors:

        Description: #{description}
        Tax description: #{tax_description || '(none)'}

        Return the corrected versions. If the text looks correct, return it unchanged.
      MSG
      answer = ask(instructions: Prompts::CLEANUP_PROMPT, schema: Prompts::CLEANUP_SCHEMA, message:)
      {
        description: present(answer[:description]) || description.to_s,
        tax_description: present(answer[:tax_description]) || tax_description
      }
    end

    private

    def ask(**)
      @llm.ask(**)
    rescue Expenses::LLM::Error => e
      raise Error, e.message
    end

    def read(file_ref)
      @file_store.read(file_ref)
    rescue FileStore::NotFound
      raise Error, 'The uploaded file is missing'
    end

    def processed_path(doc) = read(doc.processed_file_ref || doc.file_ref).path

    def pdf?(doc) = doc.content_type == 'application/pdf'

    # Spelled out so the model can't misread it as a DD/MM or MM/DD date.
    def spelled_out(date) = date.strftime('%Y-%m-%d (%-d %B %Y)')

    def distance(date, today)
      days = (today - date).to_i
      return "#{-days} days in the future, which is impossible" if days.negative?
      return 'today' if days.zero?

      "#{days} days before today"
    end

    def present(value) = value.to_s.strip.empty? ? nil : value
  end
end
