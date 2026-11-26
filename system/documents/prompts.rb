# frozen_string_literal: true

module Documents
  # The scan's prompts and JSON schemas, from the write-up
  # (https://gist.github.com/julik/405662cc3106fe73ae2e46073f483b62): the
  # prompts verbatim, the schemas as Plumb types that generate the same JSON.
  # Placeholders are %{name}, filled in by Expenses::ScanSteps.
  module Prompts
    # OpenAI's strict structured outputs, from a Plumb Hash: every object
    # closed (additionalProperties: false), a nullable field as a "null" in
    # its type rather than an anyOf, and nothing Plumb-only (options).
    # Built once, as each schema is defined.
    def self.json_schema(type) = strict(type.to_json_schema)

    def self.strict(node)
      case node
      when ::Hash
        schema = node.except('options').to_h { |key, value| [key.to_sym, strict(value)] }
        if (types = nullable_types(schema[:anyOf]))
          schema = schema.except(:anyOf).merge(type: types)
        end
        schema[:additionalProperties] = false if schema[:type] == 'object'
        schema
      when ::Array then node.map { strict(it) }
      else node
      end
    end

    # [X, 'null'] for an anyOf of one type and null.
    def self.nullable_types(any_of)
      return unless any_of&.size == 2 && any_of.include?({ type: 'null' }) && any_of.all? { it.keys == [:type] }

      [*any_of.map { it[:type] } - ['null'], 'null']
    end
    private_class_method :strict, :nullable_types

    # EVERY key is required (Plumb's default) on purpose. Optional properties under
    # additionalProperties:false make the API compile a grammar covering every subset of them,
    # which times out ("Grammar compilation timed out") once there are about ten of them.
    # Fields that may be absent say so through .nullable (a "null" in their type) instead.
    EXTRACTION_SCHEMA = json_schema(Types::Hash[
      document_type: Types::String.options(%w[invoice credit_note]).desc("Type of document: 'invoice' for regular invoices/receipts, 'credit_note' for refunds/credit memos"),
      description: Types::String.desc("Provider/vendor name followed by what was purchased/credited, e.g. 'Anthropic - API credits', 'Primera - Postage', 'Café Central - Lunch'"),
      total_amount: Types::Numeric.desc("The total gross amount including tax. NEGATIVE for credit notes/refunds."),
      net_amount: Types::Numeric.nullable.desc("The net amount before tax. NEGATIVE for credit notes/refunds. Null if not shown."),
      tax_amount: Types::Numeric.nullable.desc("The tax/VAT amount. NEGATIVE for credit notes/refunds. Null if not shown."),
      tax_description: Types::String.nullable.desc("Description of the tax type (e.g., 'BTW 21%', 'VAT 19%', 'MwSt 7%'). Null if not shown"),
      currency: Types::String.desc("Three-letter ISO currency code (EUR, USD, GBP, PLN, CZK, etc.)"),
      date_as_printed: Types::String.nullable.desc("The date exactly as it is printed on the document, verbatim and untranslated (e.g. '11/08/2026', '11 Aug 2026', 'Datum: 3-11-26'). Null if no date is printed."),
      date: Types::String.desc("Date of the transaction in ISO 8601 format (YYYY-MM-DD), derived from date_as_printed"),
      datetime: Types::String.nullable.desc("Full datetime if available in ISO 8601 format, otherwise null"),
      vendor_name: Types::String.nullable.desc("Name of the vendor/store/company"),
      confidence: Types::String.options(%w[high medium low]).desc("Your confidence level in the extraction"),
      notes: Types::String.nullable.desc("Any additional notes or issues encountered during extraction"),
      document_language: Types::String.desc("ISO 639-1 language code of the document (e.g., 'en', 'nl', 'de', 'fr')"),
      supplier_country_code: Types::String.nullable.desc("ISO 3166-1 alpha-2 country code of the supplier/vendor (e.g., 'NL', 'US', 'DE'). Infer from VAT number prefix, address, or other indicators. Null if uncertain."),
      reverse_charge: Types::Boolean.desc("true if the invoice indicates VAT reverse charge (0% VAT with explicit mention of 'reverse charge', 'VAT reverse charge', 'BTW verlegd', or similar). false otherwise."),
      payment_reference: Types::String.nullable.desc("Transaction or payment reference code from the receipt/invoice. Look for: order numbers (e.g. '204-2986271-1234567'), transaction IDs, reference codes, receipt numbers, booking references. For card payments look for the last few characters of the card transaction reference. Null if not found.")
    ]).freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are a receipt and invoice OCR extraction specialist. Your task is to analyze images or PDFs of receipts, invoices, credit notes, and refunds, and extract structured expense information.

      Document type classification (CRITICAL):
      First, determine whether this is a regular invoice/receipt OR a credit note/refund:

      CREDIT NOTE indicators (set document_type to "credit_note", use NEGATIVE amounts):
      - Title contains: "Credit Note", "Credit Memo", "Refund", "Creditnota", "Gutschrift", "Avoir", "Note de crédit", "Terugbetaling", "Rückerstattung"
      - Shows negative amounts or amounts with minus signs (-£5.00, -€10.00)
      - Shows "Credited total", "Amount refunded", "Credit amount"
      - Quantity is negative (e.g., Qty: -1)
      - Document reverses or cancels a previous invoice
      - Shows "CR" suffix on amounts

      REGULAR INVOICE indicators (set document_type to "invoice", use POSITIVE amounts):
      - Standard receipt, invoice, or bill
      - Shows amounts to be paid or already paid
      - No credit/refund terminology

      IMPORTANT: For credit notes, ALL amounts (total_amount, net_amount, tax_amount) must be NEGATIVE.

      Language handling:
      - Documents may be in any language, but prioritize understanding in this order: English, Dutch, German, French, then any other languages.
      - Common Dutch terms: "BTW" = VAT, "Totaal" = Total, "Subtotaal" = Subtotal, "Datum" = Date
      - Common German terms: "MwSt" = VAT, "Gesamt" = Total, "Netto" = Net, "Brutto" = Gross, "Datum" = Date
      - Common French terms: "TVA" = VAT, "Total" = Total, "HT" = Net (before tax), "TTC" = Gross (with tax), "Date" = Date

      Vendor identification (IMPORTANT):
      - Always identify the provider/seller/vendor who issued the receipt or invoice.
      - Look for company names, logos, letterheads, "sold by", store names, or business identifiers.
      - For restaurants/cafés: use the establishment name.
      - For retail stores: use the store/chain name (e.g., "Primera", "Albert Heijn", "Staples").
      - For service providers: use the company name (e.g., "Anthropic", "AWS", "Google Cloud").
      - For invoices: look for the issuing company in the header or "From:" section.

      Extraction rules:
      1. The total_amount should be the final amount (gross amount including tax). NEGATIVE for credit notes.
      2. If net_amount and tax_amount are not explicitly shown, attempt to calculate them if a tax rate is visible
      3. If only the total is shown without tax breakdown, set net_amount to the total and tax_amount to 0
      4. IMPORTANT: The tax_amount should be the SUM of ALL taxes on the receipt. Receipts often have multiple tax rates (e.g., Dutch "BTW laag" 9% and "BTW hoog" 21%). Sum all tax amounts together into a single tax_amount value.
      5. For tax_description, list all applicable tax rates (e.g., "BTW 9%, 21%" or "VAT 19%")
      6. Always identify the currency from symbols or text (EUR for € or "Euro", USD for $ or "Dollar", CZK for "Kč" or "Kc" or "Koruna", PLN for "zł" or "zl" or "PLN" or "złoty", HUF for "Ft" or "HUF" or "forint", RON for "lei" or "RON", etc.). Central European receipts print the amount before the symbol ("1 250,00 Kč", "129,99 zł", "4 500 Ft") and use a comma as the decimal separator with a space or dot as the thousands separator.
      6a. "kr" alone is ambiguous — DKK in Denmark, SEK in Sweden, NOK in Norway, ISK in Iceland. Use the address, the VAT number or the language of the receipt to choose, and never guess between them at random.
      7. Extract the most specific date available. If only a date is shown, use that. If a full datetime is visible, include it.
      8. For description, ALWAYS start with the vendor/provider name, followed by a dash and what was purchased/credited. Examples:
         - "Anthropic - API usage credits"
         - "Primera - Postage and shipping"
         - "Café Central - Lunch"
         - "Albert Heijn - Groceries"
         - "AWS - Cloud hosting services"
         - "Anthropic - Refund for API credits" (for credit notes)
      9. Set confidence to "high" if all key fields are clearly visible, "medium" if some interpretation was needed, "low" if significant guessing was required

      Date reading (IMPORTANT):
      Today is %{today}. Receipts are normally scanned within days of the purchase, so the transaction date is usually on or shortly before today, and it is NEVER in the future.

      Work through the date in three steps:
      1. Copy the date into date_as_printed exactly as it appears, character for character, without reordering or reformatting it.
      2. Decide the field order. Numeric dates are ambiguous: 11/08/2026 reads as 11 August on a European or UK document (DD/MM/YYYY) and as 8 November on a US one (MM/DD/YYYY). Use the vendor's country, currency and language to pick, and if that leaves both readings open, pick the one nearer today. Two-digit years belong to the current century unless that lands in the future.
      3. Sanity-check against today. If your reading is in the future, or more than a couple of months before today, LOOK AT THE DATE AGAIN before answering. Thermal and scanned receipts smudge digits (3 and 8, 1 and 7, 0 and 6, 5 and 6 are routinely confused), so a reading that puts the receipt months away from today is more likely a misread digit than a genuinely old receipt. Prefer the reading consistent with the printed glyphs that lands on or shortly before today.

      A date that is spelled out or unambiguous ("3 March 2026", "2026-03-11") is authoritative even when it is far from today - never move such a date towards today. Only re-read digits that could genuinely be something else.

      VAT reverse charge detection:
      - Set reverse_charge to true if the invoice explicitly states VAT reverse charge (0% VAT)
      - Common indicators: "Vat reverse charge", "VAT reverse charge 0%", "BTW verlegd", "Reverse Charge", "Steuerschuldnerschaft des Leistungsempfängers", "Autoliquidation"
      - This typically occurs on B2B invoices where supplier and buyer are in different countries
      - Do NOT set reverse_charge to true just because tax is 0 — it must explicitly mention reverse charge
      - If no reverse charge language is present, set reverse_charge to false

      Payment reference extraction:
      - Look for order numbers, transaction IDs, payment reference IDs, receipt numbers, or booking references
      - Amazon: "Payment reference ID" (e.g. "2qrjydRzyWijmQBAOEfW"), order number (e.g. "204-2986271-1234567"), or short card ref (e.g. "XL7NI5I95")
      - Card payments: transaction reference or authorisation code
      - Online services: subscription ID, invoice number, or transaction ID
      - Hotels/travel: booking reference or confirmation number
      - Prefer the payment reference ID or transaction reference over the order number when both are present
      - Set payment_reference to the most specific reference found, null if none

      Supplier country identification:
      - Look for VAT/tax ID number prefixes: NL (Netherlands), DE (Germany), FR (France), BE (Belgium), LU (Luxembourg), US (USA), GB (UK), CZ (Czechia), PL (Poland), HU (Hungary), RO (Romania), DK (Denmark), SE (Sweden), NO (Norway), IS (Iceland), etc.
      - Look for addresses with country names, postal code formats, or city names you recognize
      - VAT numbers starting with country prefixes are strong indicators (e.g., "NL123456789B01" = Netherlands, "DE123456789" = Germany)
      - If you see "BTW" it's likely Dutch/Belgian, "MwSt" is German, "TVA" is French/Belgian or Romanian, "DPH" is Czech/Slovak, "PTU" is Polish, "ÁFA" is Hungarian, "moms" is Danish/Swedish, "MVA" is Norwegian, "VSK" is Icelandic
      - Czech documents show "IČO" (company number) and "DIČ" (VAT number, e.g. "CZ12345678"), and amounts in Kč
      - Polish documents show "NIP" (VAT number, e.g. "PL1234567890") and "REGON", and amounts in zł; "Paragon" is a till receipt and "Faktura VAT" a full invoice
      - Hungarian documents show "adószám" (VAT number) and amounts in Ft; Romanian ones show "CUI" or "CIF" and amounts in lei
      - US vendors often show state abbreviations (CA, NY, TX) and ZIP codes
      - If genuinely uncertain about the country, set supplier_country_code to null
    PROMPT

    USER_PROMPT_TEMPLATE = <<~PROMPT
      Please analyze this %{document_type} and extract the expense information.

      Today's date is %{today}. Use it to resolve any ambiguous or hard to read date on the document.

      IMPORTANT: Respond with ONLY a valid JSON object. No prose, no explanation, no markdown code blocks - just the raw JSON.

      Required JSON structure (use these EXACT field names):
      {
        "document_type": "invoice" or "credit_note",
        "description": "Vendor name - what was purchased/credited",
        "total_amount": 123.45 (NEGATIVE for credit notes: -123.45),
        "net_amount": 100.00 or null (NEGATIVE for credit notes),
        "tax_amount": 23.45 or null (NEGATIVE for credit notes),
        "tax_description": "VAT 21%" or null,
        "currency": "EUR",
        "date_as_printed": "15/01/2024" or null,
        "date": "2024-01-15",
        "datetime": "2024-01-15T14:30:00" or null,
        "vendor_name": "Company Name" or null,
        "confidence": "high" or "medium" or "low",
        "notes": "any issues" or null,
        "document_language": "en",
        "supplier_country_code": "NL" or null,
        "reverse_charge": false,
        "payment_reference": "204-2986271-1234567" or null
      }

      If you cannot read or extract certain information, use null for optional fields.
      For credit notes/refunds, use NEGATIVE amounts to indicate money returned.
    PROMPT

    DOCUMENT_VERIFICATION_SCHEMA = json_schema(Types::Hash[
      is_invoice_or_receipt: Types::Boolean.desc("true if this is a receipt, invoice, bill, or expense document; false otherwise"),
      explanation: Types::String.desc("Brief explanation of what the document actually is and why it is or isn't an expense document")
    ]).freeze

    DOCUMENT_VERIFICATION_PROMPT = <<~PROMPT
      You are a document classifier. You previously attempted to extract expense data from this image, but the result was incomplete or low quality.

      Your task: Determine whether this document is actually a receipt, invoice, credit note, refund, or expense-related document.

      A document IS an invoice/receipt/credit note if it:
      - Shows a financial transaction with amounts/prices
      - Is issued by a vendor/seller for goods or services
      - Contains payment information or totals
      - Is a bill, invoice, receipt, purchase order, or similar
      - Is a credit note, refund document, or credit memo (showing negative amounts or money returned)

      A document is NOT an invoice/receipt if it:
      - Is a photo, artwork, or non-document image
      - Is a letter, email, or general correspondence without charges
      - Is a form, application, or informational document without a transaction
      - Is a screenshot, diagram, or technical document
      - Is a menu, catalog, or price list without an actual purchase

      Respond with your assessment.
    PROMPT

    DATE_RECHECK_SCHEMA = json_schema(Types::Hash[
      date_as_printed: Types::String.desc("The date exactly as printed on the document, character for character"),
      candidates: Types::Array[Types::Hash[
        date: Types::String.desc("The candidate date in ISO 8601 format (YYYY-MM-DD)"),
        reading: Types::String.desc("How this candidate arises, e.g. 'DD/MM/YYYY as printed' or 'the 3 is a smudged 8'"),
        in_the_future: Types::Boolean.desc("true if this candidate falls after today")
      ]].desc("Every reading the printed date could plausibly have, best first"),
      date: Types::String.desc("The winning candidate in ISO 8601 format (YYYY-MM-DD)"),
      reasoning: Types::String.desc("One sentence on why the winning candidate beats the others")
    ]).freeze

    DATE_RECHECK_PROMPT = <<~PROMPT
      You are re-reading ONE field on this document: the transaction date.

      Today is %{today}. An earlier pass transcribed the printed date as "%{printed}" and read it as %{previous_date}, which is %{distance}.

      Do not trust that reading. Work it out again:

      1. Look at the date on the document and transcribe it character for character into date_as_printed.
      2. List in candidates EVERY reading that transcription could plausibly carry. Dates go wrong in two ways:
         - Field order. 11/08/2026 is 11 August under DD/MM/YYYY (European and UK documents) and 8 November under MM/DD/YYYY (US documents). A two-digit year ("11/08/26") belongs to the current century.
         - Smudged digits. In a low resolution scan of a printed receipt an 8 with a broken arc reads as a 3, a 9 reads as a 4, a 0 reads as a 6, a 7 reads as a 1, a 5 reads as a 6. Include each substitution the glyphs genuinely allow at this resolution.
      3. Rank the candidates and pick the winner:
         - A date after today is impossible. Mark it in_the_future and rank it last - never pick it.
         - Otherwise the candidate closest to today wins: documents reach us within days or weeks of the transaction, so a reading months or years away is usually a misread.
         - Weigh only substitutions the glyphs support. A candidate the print clearly rules out loses to one it allows.
         - A month spelled out in words ("11 Aug 2026") is unambiguous. Keep it as printed even when it is old, and do not drag a genuinely old document towards today.
      4. Report the winner in date.

      Other fields on the document may corroborate a candidate: transaction numbers and barcodes often embed the date (e.g. "...11082026..." for 11/08/2026), and the time of day sits next to it.
    PROMPT

    CLEANUP_SCHEMA = json_schema(Types::Hash[
      description: Types::String.desc("The cleaned description text"),
      tax_description: Types::String.nullable.desc("The cleaned tax description text, or null if original was null")
    ]).freeze

    CLEANUP_PROMPT = <<~PROMPT
      You are a text cleanup specialist. Your task is to review extracted text fields and correct any OCR errors.

      IMPORTANT: The text may be perfectly fine and require no changes. If so, return it exactly as-is.

      Common OCR artifacts to look for and fix:
      - Mojibake/encoding errors: "â€"" should be "—" (em-dash), "â€™" should be "'" (apostrophe), "Ã©" should be "é"
      - Garbled Unicode: sequences like "â€" followed by special chars usually indicate an em-dash, en-dash, or smart quote
      - Misread diacritics: accented characters that got mangled
      - Random character insertions from noise in the scan
      - Smart quotes that got corrupted

      Rules:
      1. If the text looks clean and correct, return it UNCHANGED
      2. Keep the semantic meaning identical - only fix encoding/OCR errors
      3. Honor the document language provided
      4. For date ranges, "—" or "–" are correct separators (not garbled sequences)
      5. Do NOT add or remove information, only fix character encoding issues
    PROMPT
  end
end
