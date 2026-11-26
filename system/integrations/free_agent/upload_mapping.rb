# frozen_string_literal: true

require 'base64'
require 'bigdecimal'
require 'date'
require 'tmpdir'

module Integrations
  module FreeAgent
    # A filed expense (Expenses::ExpenseState) as FreeAgent's expense
    # attributes, to create or update one with: ExpenseMapping the other way.
    #
    #   UploadMapping.attributes(doc, user:, categories: client.categories, company_currency: 'GBP')
    #   # => { user:, category:, dated_on:, currency:, gross_value:, ec_status:, ... }
    #
    # Its figures are what was filed. Anything it can't say the way FreeAgent
    # books it raises Refused, with why, for the expense's page: an expense
    # is better not uploaded than booked wrong.
    #
    # - +user+: the claimant, the connected person (Client#current_user_url).
    # - +category+: FreeAgent's category of the same name as the expense's
    #   (ExpenseMapping.ours, ALIASES included), or one of FreeAgent's own
    #   that came here with an import (use_of_home is "Use of home").
    # - +gross_value+: negative, money paid out to the claimant, VAT included.
    # - VAT, by the expense's treatment:
    #     domestic        UK/Non-EC, at FreeAgent's standard rate the figures
    #                     make (20%, 5%, 0%), in the company's currency only
    #     reverse_charge  Reverse Charge (EC Services before 2021)
    #     no_vat          UK/Non-EC, zero rated
    #     foreign_vat     UK/Non-EC, out of scope: not reclaimable here
    #     import          not uploaded: import VAT is entered on FreeAgent
    #
    # .attachment is its document's file, the way FreeAgent takes one.
    module UploadMapping
      # Why an expense can't be uploaded, for a person to read.
      Refused = Class.new(Error)

      # Its document's file couldn't go with it: why, for a person to read.
      # The expense is uploaded all the same.
      NoAttachment = Class.new(Error)

      # What FreeAgent takes as an attachment: its types (ours => FreeAgent's
      # names for them), up to 5 MB.
      ATTACHMENT_TYPES = {
        'application/pdf' => 'application/x-pdf', 'image/jpeg' => 'image/jpeg',
        'image/png' => 'image/png', 'image/gif' => 'image/gif'
      }.freeze
      ATTACHMENT_MAX_BYTES = 5_000_000

      STANDARD_RATES = [20, 5, 0].freeze
      REVERSE_CHARGE_FROM = Date.new(2021, 1, 1)

      # @param doc [Expenses::ExpenseState] a filed expense
      # @param user [String] the claimant's url
      # @param categories [Hash{String => Client::Category}] FreeAgent's, by url
      # @param company_currency [String, nil] the company's own currency
      # @return [Hash] FreeAgent's attributes
      # @raise [Refused]
      def self.attributes(doc, user:, categories:, company_currency:)
        filed = doc.filed or raise Refused, 'It isn’t filed'
        net = cents(filed[:net_price_cents])
        tax = cents(filed[:tax_amount_cents])
        {
          user:,
          category: category_url(doc, categories),
          dated_on: filed[:incurred_on].iso8601,
          currency: filed[:currency],
          description: filed[:description],
          gross_value: format('%.2f', -(net + tax)),
          receipt_reference: filed[:payment_reference],
          **vat(doc.vat_treatment, filed, net, tax, company_currency)
        }.compact
      end

      # FreeAgent's category for the expense's: the same name, or the one it
      # came from.
      def self.category_url(doc, categories)
        key = doc.category or raise Refused, 'It has no category'
        found = categories.values.find { ExpenseMapping.ours(it.description) == key } ||
                categories.values.find { Expenses.category_key(it.description) == key }
        return found.url if found

        raise Refused, "No category on FreeAgent is “#{Expenses.category_label(key)}”: choose another, " \
                       'or name it in Integrations::FreeAgent::ExpenseMapping::ALIASES'
      end

      def self.vat(treatment, filed, net, tax, company_currency)
        case treatment
        when 'reverse_charge'
          { ec_status: filed[:incurred_on] < REVERSE_CHARGE_FROM ? 'EC Services' : 'Reverse Charge' }
        when 'no_vat'
          { ec_status: 'UK/Non-EC', sales_tax_rate: '0.0' }
        when 'foreign_vat'
          { ec_status: 'UK/Non-EC', sales_tax_status: 'OUT_OF_SCOPE' }
        when 'domestic'
          { ec_status: 'UK/Non-EC', sales_tax_rate: format('%.1f', domestic_rate(filed, net, tax, company_currency)) }
        when 'import'
          raise Refused, 'Import VAT isn’t uploaded: enter this one on FreeAgent'
        else
          raise Refused, 'It has no VAT treatment'
        end
      end

      # The standard rate whose VAT on the gross is exactly the VAT filed, to
      # the penny, as FreeAgent works it out from the rate: anything else
      # would book a different VAT. FreeAgent ignores a rate on an expense in
      # another currency than the company's, wanting the VAT as an amount in
      # its own: not something to guess.
      def self.domestic_rate(filed, net, tax, company_currency)
        return 0 if tax.zero?
        if company_currency.nil? || filed[:currency] != company_currency
          raise Refused, "VAT on an expense in #{filed[:currency]}, not the company’s currency: enter this one on FreeAgent"
        end

        gross = net + tax
        standard = STANDARD_RATES.find { it.positive? && (gross * it / (100 + it)).round(2) == tax }
        standard or raise Refused, "VAT of #{format('%.2f', tax)} on #{format('%.2f', gross)} isn’t one of FreeAgent’s " \
                                   'standard rates exactly: enter this one on FreeAgent'
      end

      # The expense's document's file (+document+: a Documents::DocumentState)
      # as FreeAgent's +attachment+: the file uploaded, if FreeAgent takes it
      # as it is, or else the smaller JPEG its scan made of a photo, or one
      # made now (a WebP, say). A PDF too big for FreeAgent isn't sent.
      # @param file_store [#read]
      # @return [Hash] FreeAgent's attachment: +data+, +file_name+, +content_type+
      # @raise [NoAttachment]
      def self.attachment(document, file_store:)
        original = stored(file_store, document.file_ref)
        if fits?(original, document.content_type)
          return attachment_of(original.path, document.filename, document.content_type)
        end

        name = "#{File.basename(document.filename.to_s, '.*')}.jpg"
        processed = document.processed_file_ref && document.processed_file_ref != document.file_ref &&
                    stored(file_store, document.processed_file_ref)
        return attachment_of(processed.path, name, 'image/jpeg') if processed && fits?(processed, 'image/jpeg')

        if document.content_type.to_s.start_with?('image/')
          return Dir.mktmpdir do |dir|
            attachment_of(Documents::Images.shrink(original.path, File.join(dir, name)), name, 'image/jpeg')
          end
        end

        raise NoAttachment, "Its file is over #{ATTACHMENT_MAX_BYTES / 1_000_000} MB, more than FreeAgent takes: " \
                            'attach it on FreeAgent'
      rescue Documents::Images::Error => e
        raise NoAttachment, "Its file couldn’t be made into one FreeAgent takes (#{e.message}): attach it on FreeAgent"
      end

      def self.stored(file_store, id)
        file_store.read(id)
      rescue FileStore::NotFound
        raise NoAttachment, 'Its file is missing here'
      end

      def self.fits?(file, content_type)
        ATTACHMENT_TYPES.key?(content_type) && file.size <= ATTACHMENT_MAX_BYTES
      end

      def self.attachment_of(path, file_name, content_type)
        { data: Base64.strict_encode64(File.binread(path)), file_name:, content_type: ATTACHMENT_TYPES.fetch(content_type) }
      end

      def self.cents(value) = BigDecimal(value.to_i) / 100

      private_class_method :category_url, :vat, :domestic_rate, :cents, :stored, :fits?, :attachment_of
    end
  end
end
