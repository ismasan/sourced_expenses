# frozen_string_literal: true

require 'json'

module UI
  module Components
    # A message's trail, in a dialog: every message in the store that shares
    # its correlation id, as a tree of what caused what. One workflow,
    # whatever streams it crosses: a document read, the expense it drafted,
    # that expense uploaded to FreeAgent. Each message says which reactor
    # produced it, links to the page of the record it's about, and shows its
    # payload when asked. The message it was opened from is marked.
    #
    # HistoryFeed opens it (App's GET /messages/:message_id/trail patches it
    # in), and +at+, the page at that message's step, is linked from it.
    class MessageTrail < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/message_trail.css', path: 'message_trail.css'

      ID = 'message-trail'

      # A stored message, read from its row rather than its class: one whose
      # type is no longer known still shows. +kind+ is HistoryFeed's
      # (:command, :checkpoint, :data), or :unknown.
      Entry = ::Data.define(:position, :id, :type, :causation_id, :producer, :payload, :created_at, :kind)
      Node = ::Data.define(:entry, :children)

      # The trail of the message +message_id+: its correlation's messages,
      # in the order they were stored. Empty for a message the store hasn't.
      # @return [Array<Entry>]
      def self.entries(message_id, store: Sourced.store)
        messages = store.db[store.installer.messages_table]
        correlation_id = messages.where(message_id:).get(:correlation_id) or return []

        messages.where(correlation_id:).order(:position).map { entry(it) }
      end

      def self.entry(row)
        payload = JSON.parse(row[:payload].to_s) rescue {} # rubocop:disable Style/RescueModifier
        metadata = row[:metadata] ? JSON.parse(row[:metadata]) : {}
        Entry.new(position: row[:position], id: row[:message_id], type: row[:message_type],
                  causation_id: row[:causation_id], producer: metadata['producer'], payload:,
                  created_at: time(row[:created_at]), kind: kind(row[:message_type], payload))
      end

      # SQLite keeps it as ISO 8601 text.
      def self.time(value) = value.is_a?(Time) ? value : Time.iso8601(value.to_s)

      def self.kind(type, payload)
        klass = Sourced::Message.registry[type]
        if klass.nil? then :unknown
        elsif klass <= Sourced::Command then :command
        elsif klass <= Sourced::Machine::State && payload.key?('target') then :checkpoint
        else :data
        end
      end

      # +entries+ as trees: each message under the one that caused it, the
      # first (and any whose cause isn't in the trail) at the top.
      # @return [Array<Node>]
      def self.tree(entries)
        nodes = entries.to_h { [it.id, Node.new(entry: it, children: [])] }
        nodes.values.each_with_object([]) do |node, roots|
          parent = node.entry.causation_id != node.entry.id && nodes[node.entry.causation_id]
          parent ? parent.children << node : roots << node
        end
      end

      private_class_method :entry, :time, :kind

      # Where the dialog goes, until a message is clicked: left alone when the
      # page around it is patched, so one open stays open.
      def self.placeholder(component) = component.div(id: ID, hidden: true, data: { 'ignore-morph' => true })

      # @param entries [Array<Entry>] .entries
      # @param selected [String] the id of the message it was opened from
      # @param at [String, nil] the page at that message's step
      def initialize(entries, selected:, at: nil)
        @entries = entries
        @roots = self.class.tree(entries)
        @selected = selected
        @at = at
      end

      def view_template
        dialog(id: ID, class: 'trail', aria: { labelledby: "#{ID}-title" },
               data: { init: 'el.showModal()', 'on:click' => 'evt.target === el && el.close()', 'ignore-morph' => true }) do
          header(class: 'trail__bar') do
            div(class: 'trail__heading') do
              h2(id: "#{ID}-title", class: 'trail__title') { 'Message trail' }
              p(class: 'trail__summary') { overview }
            end
            if @at
              a(class: 'trail__at', href: @at,
                data: { 'on:click__prevent' => "document.getElementById('#{ID}').close(); @get('#{@at}')" }) do
                'Page at this step'
              end
            end
            form(method: 'dialog') { button(class: 'trail__close', autofocus: true, aria: { label: 'Close' }) { '×' } }
          end
          div(class: 'trail__body') do
            if @roots.empty?
              p(class: 'trail__empty') { 'This message isn’t in the store.' }
            else
              ol(class: 'trail__tree') { @roots.each { render_node(it) } }
            end
          end
        end
      end

      private

      def overview
        first, last = @entries.first, @entries.last
        return '' unless first

        span = first.created_at == last.created_at ? '' : ", #{duration(last.created_at - first.created_at)}"
        "#{@entries.size} messages, #{streams} #{streams == 1 ? 'stream' : 'streams'}#{span}, " \
          "from #{first.created_at.localtime.strftime('%-d %b %Y, %H:%M:%S')}"
      end

      def streams = @entries.map { record(it)&.first(2) || [:system] }.uniq.size

      def render_node(node)
        entry = node.entry
        selected = entry.id == @selected
        li(class: 'trail__node') do
          div(class: ['trail__card', "trail__card--#{entry.kind}", ('is-selected' if selected)],
              id: ("#{ID}-selected" if selected), aria: { current: selected ? 'true' : nil },
              data: (selected ? { init: "el.scrollIntoView({block: 'center'})" } : {})) do
            div(class: 'trail__line') do
              span(class: 'trail__position') { "##{entry.position}" }
              span(class: 'trail__kind') { entry.kind.to_s }
              span(class: 'trail__type') { entry.type }
              time(class: 'trail__time', datetime: entry.created_at.iso8601) { entry.created_at.localtime.strftime('%H:%M:%S') }
            end
            div(class: 'trail__meta') do
              span(class: 'trail__by') { "by #{entry.producer}" } if entry.producer
              if (link = record(entry))
                a(class: 'trail__record', href: link[2]) { link[0..1].join(' ') }
              end
              span { 'no longer a known type' } if entry.kind == :unknown
            end
            unless entry.payload.empty?
              details(class: 'trail__payload') do
                summary { 'Payload' }
                pre { JSON.pretty_generate(entry.payload) }
              end
            end
          end
          ol(class: 'trail__children') { node.children.each { render_node(it) } } if node.children.any?
        end
      end

      # The record a message is about, as [noun, short id, its page], or nil.
      def record(entry)
        about = entry.payload
        if about['expense_id'] then ['expense', short(about['expense_id']), "/expenses/#{about['expense_id']}"]
        elsif about['document_id'] then ['document', short(about['document_id']), "/documents/#{about['document_id']}"]
        elsif (account = about['import_id'] || about['account'])
          ['FreeAgent', account.to_s, '/integrations/freeagent']
        end
      end

      def short(id) = id.to_s[0, 8]

      def duration(seconds)
        return "#{seconds.round(1)}s" if seconds < 60
        return "#{(seconds / 60).round}m" if seconds < 3600

        "#{(seconds / 3600).round(1)}h"
      end
    end
  end
end
