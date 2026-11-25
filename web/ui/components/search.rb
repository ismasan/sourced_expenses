# frozen_string_literal: true

module UI
  module Components
    # Search, on every page: a magnifier button in the top bar that opens a
    # modal (a <dialog>) with the search box, as do / (unless typing in a
    # field already) and Cmd/Ctrl+K from anywhere. As a person types, it
    # previews the first few matches (SearchPreview, from GET /search) under
    # the box; the arrow keys move through them and Enter visits one
    # (NAVIGATE). Escape, or a click outside it, closes it.
    #
    # The box is a plain GET form to the list (/expenses?q=…): Enter with
    # nothing highlighted lists every match there.
    #
    # Outside the page's element, so a live re-render of the page never
    # clears what's typed. Its signal is local (_q): never sent to the
    # server, so the query goes in the URL.
    class Search < Sidereal::Components::BaseComponent
      stylesheet 'ui/components/search.css', path: 'search.css'

      # How long typing pauses before the preview is fetched.
      DEBOUNCE = '200ms'

      # The preview of what's typed, unless it's blank.
      FETCH = "$_q.trim() && @get('/search?q=' + encodeURIComponent($_q.trim()))"

      # The class on the preview's link highlighted with the arrow keys.
      ACTIVE = 'search-preview__link--active'

      # Opens the modal, the box focused with what's in it selected to type
      # over, and no match highlighted. Its preview, if it has none yet for
      # a search in the box (the list's, or one typed before), is fetched by
      # the box's focus.
      OPEN = <<~JS.tr("\n", ' ').freeze
        const dialog = document.getElementById('search-dialog');
        if (!dialog.open) dialog.showModal();
        const box = document.getElementById('search-q');
        dialog.querySelectorAll('.#{ACTIVE}').forEach(l => l.classList.remove('#{ACTIVE}'));
        box.removeAttribute('aria-activedescendant');
        box.focus();
        box.select();
      JS

      SHORTCUT = <<~JS.tr("\n", ' ').freeze
        const typing = evt.target.closest('input, textarea, select, [contenteditable]');
        if ((evt.key === '/' && !typing && !evt.metaKey && !evt.ctrlKey && !evt.altKey) ||
            (evt.key === 'k' && (evt.metaKey || evt.ctrlKey))) {
          evt.preventDefault();
          #{OPEN}
        }
      JS

      # The shortcut as this computer's keyboard has it: ⌘K on a Mac.
      MAC_KEY = "/Mac|iPhone|iPad/.test(navigator.platform) && (el.textContent = '⌘K')"

      FOCUS = "!document.querySelector('#search-preview').children.length && #{FETCH}".freeze

      # Down and up move a highlight through the preview's links (each
      # match, then the link to them all), focus staying in the box so
      # typing goes on; up from the first goes back to none. Enter visits
      # the one highlighted, or with none, submits the form: the list. The
      # highlight is a class on the link, so a new preview, rendered
      # without it, starts from none.
      NAVIGATE = <<~JS.tr("\n", ' ').freeze
        const links = [...document.querySelectorAll('#search-preview a')];
        const at = links.findIndex(l => l.classList.contains('#{ACTIVE}'));
        if (links.length && (evt.key === 'ArrowDown' || evt.key === 'ArrowUp')) {
          evt.preventDefault();
          const to = evt.key === 'ArrowDown' ? Math.min(at + 1, links.length - 1) : Math.max(at - 1, -1);
          links.forEach((l, i) => l.classList.toggle('#{ACTIVE}', i === to));
          if (to >= 0) { links[to].scrollIntoView({ block: 'nearest' }); el.setAttribute('aria-activedescendant', links[to].id) }
          else { el.removeAttribute('aria-activedescendant') }
        }
        if (evt.key === 'Enter' && at >= 0) { evt.preventDefault(); links[at].click() }
      JS

      # @param query [String, nil] what the list is searched for now, if anything
      def initialize(query)
        @query = query.to_s
      end

      def view_template
        button(type: 'button', class: 'search-button', title: 'Search (/ or Cmd/Ctrl+K)',
               aria: { label: 'Search expenses', haspopup: 'dialog', controls: 'search-dialog', keyshortcuts: '/ Meta+K Control+K' },
               data: { 'on:click' => OPEN, 'on:keydown__window' => SHORTCUT }) do
          span(class: 'search-button__icon', aria: { hidden: 'true' })
          kbd(class: 'search-button__key', aria: { hidden: 'true' }, data: { init: MAC_KEY }) { 'Ctrl K' }
        end

        # A click on the backdrop is a click on the dialog itself.
        dialog(id: 'search-dialog', class: 'search', aria: { label: 'Search expenses' },
               data: { 'signals' => JSON.generate(_q: @query), 'on:click' => 'evt.target === el && el.close()' }) do
          form(class: 'search__form', action: ExpensesPage.path, method: 'get', role: 'search') do
            label(for: 'search-q', class: 'search__label') { 'Search expenses' }
            input(id: 'search-q', class: 'search__input', type: 'text', name: 'q', value: @query,
                  placeholder: 'Search expenses', autocomplete: 'off', spellcheck: 'false',
                  aria: { controls: 'search-preview' },
                  data: { 'bind' => '_q', 'on:focus' => FOCUS, 'on:keydown' => NAVIGATE,
                          "on:input__debounce.#{DEBOUNCE}" => FETCH })
            # Escape closes it too; this is for a touch screen.
            button(type: 'button', class: 'search__close', aria: { label: 'Close search' },
                   data: { 'on:click' => "document.getElementById('search-dialog').close()" }) { 'esc' }
          end
          div(class: 'search__results', data: { show: "$_q.trim() !== ''" }) do
            div(id: 'search-preview', aria: { live: 'polite' })
          end
          p(class: 'search__hint', aria: { hidden: 'true' }) do
            kbd { '↑' }
            kbd { '↓' }
            plain ' to move · '
            kbd { 'Enter' }
            plain ' to open · '
            kbd { 'esc' }
            plain ' to close'
          end
        end
      end
    end
  end
end
