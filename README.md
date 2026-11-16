# Sourced Expenses

A [Sidereal](https://github.com/ismasan/sidereal) + [Sourced](https://github.com/ismasan/sourced) app that tracks expenses from scanned receipts and invoices, after [this write-up](https://gist.github.com/julik/405662cc3106fe73ae2e46073f483b62). Uploads are scanned with OpenAI and listed on the home page as they go; there's no review form yet.

## Expenses

`Expenses::Expense` (`system/expenses/`) is one machine per uploaded document: `UploadDocument` → `scanning` → `reviewing` → `SaveExpense` → `filed`.

- `Expense::Scanning` is the OCR pipeline. Each LLM call is a state (`extracting`, `verifying`, `rechecking_date`, `cleaning`) waiting for its worker's `Complete…` or `Fail…`. The decisions between them are transient states with guards (`checking_extraction`, `checking_date`) over plain Ruby in `Expenses::Document`.
- A failed date recheck or cleanup keeps the first reading. A failed preparation, extraction or verification fails the scan, and so does the `after` timer (`SCAN_TIMEOUT`, default `10m`). From there a person can rescan or fill in the form by hand.
- `Expense::Filed` holds the VAT treatment: inferred by rule (never by the model), flagged for review when it's foreign VAT, and kept for good once a person confirms one. Corrections are saved in place.

`Expenses::Scanner` is the worker for scanning: when an expense enters one of its waiting states, it does that step (`Expenses::ScanSteps`, with the write-up's prompts in `Expenses::Prompts`) and reports back with the step's `Complete…` or `Fail…`. It's a consumer group of its own, so a model call never holds up the machine, and turns what a step can expect to go wrong (the model, the image, a missing file, an answer that doesn't fit) into `Fail…` with a reason safe to show. Images over 500 KB are shrunk with ImageMagick first. `Expenses::Submissions` is the read model the home page lists, and the list re-renders whenever it commits.

`Expenses::UsdConverter` converts each filed expense's total (VAT included) to US dollars at the European Central Bank's rate for its date, from the [Frankfurter API](https://frankfurter.dev), and records it on the expense (`UsdAmountRecorded`, or `UsdConversionFailed` with a reason). Expenses already in USD are left alone. A correction to the amount, currency or date converts again. It's a consumer group of its own too, and on a store with expenses already filed it catches up on them when it first starts.

`Expenses::UsdLedger` is the read model for totals in US dollars: one row per filed expense (table `usd_ledger`), with its USD amount once converted. Expenses in USD count as they are; a correction to the total clears the USD amount until it's converted again; voided expenses leave it. `UsdLedger.month(db, date)` totals a month by the expenses' own dates, saying how many aren't converted yet. The All expenses page shows this month's.

Uploads land in `FileStore::Disk` (`storage/uploads/`), by the MD5 of their bytes.

`Sourced::Machine::Mermaid.new(Expenses::Expense).to_s` draws the chart. The Sourced dashboard is mounted at `/sourced`.

Message attributes use the app's `Types` (`system/types.rb`, Sourced's types): `Types::String.present`, `Types::Boolean`. Plain scalars are Ruby's own classes: `String`, `Integer`, `Date`.

## Run

```sh
bundle install
bundle exec sequel -m db/migrations sqlite://storage/db.db
bin/dev
```

Scanning needs `OPENAI_API_KEY`, from the environment or `.env` (never committed), and ImageMagick's `magick` (`brew install imagemagick`). `OPENAI_MODEL` picks another model than `gpt-4.1`. Specs fake the model and never call OpenAI. Exchange rates need no key; `EXCHANGE_RATES_URL` points at another Frankfurter instance, and specs fake them too.

Then open <http://localhost:9292>. `PORT`, `HOST` and `COUNT` (worker processes) can be set in the environment.

The migrations in `db/migrations/` are committed and `storage/` isn't, so running them is how a checkout gets its database — copy one over instead if you'd rather keep the data.

`bin/dev` runs `bundle exec falcon host` and reloads the app whenever a Ruby file changes. Reloading needs a file watcher: [watchexec](https://github.com/watchexec/watchexec) (`brew install watchexec`) or fswatch. Without one, the server still runs. In production, run `bundle exec falcon host`.

## Test

```sh
bundle exec rspec
```

## Database

The `db` component in `config/components/db.rb` is a SQLite database under `storage/` (`storage/db.db`), which classes reach with `dep :db`. Migrations are [Sequel](https://sequel.jeremyevans.net/rdoc/files/doc/migration_rdoc.html)'s, run with its command line:

```sh
bundle exec sequel -m db/migrations sqlite://storage/db.db                # run the ones not run yet
bundle exec sequel -m db/migrations -M 20261115190000 sqlite://storage/db.db  # back to that version
```

A new migration is a file in `db/migrations/` named `<timestamp>_<name>.rb`, with a `Sequel.migration` block.

Sourced keeps the app's commands and events in the same database, in tables its own migration creates (`db/migrations/20261011220710_create_sourced_tables.rb`).

## Layout

| Path | What's in it |
| --- | --- |
| `boot.rb` | Loads and configures the app |
| `config/components/` | Components: the connections, clients and other services the app's classes use, declared with `Sidereal.config`. `boot.rb` loads every file here. See `example.rb` |
| `system/` | Backend code that doesn't know about the web: messages, commanders, Sourced deciders and reactors |
| `web/app.rb` | `App`, the web app: commands it accepts, their handlers, and pages |
| `web/ui/` | Pages and the layout, in the `UI` namespace |
| `web/ui/components/` | Components used by pages, in `UI::Components` |
| `web/public/` | Static files |
| `db/migrations/` | Database migrations, run with `bundle exec sequel -m db/migrations sqlite://storage/db.db` |
| `storage/` | Runtime data, including the SQLite database. Not committed. |
| `falcon.rb` | Falcon server settings |
| `bin/dev` | Development server that reloads on code changes |
| `skills/` | Skills that teach AI coding agents to work with this app. `.claude/skills` and `.agents/skills` link here, where agents look for them |

Classes in `system/` and `web/` are loaded by [Zeitwerk](https://github.com/fxn/zeitwerk): name a file after the class it defines and use the class anywhere, without `require`. Directories under `web/` are namespaces, so `web/ui/welcome_page.rb` defines `UI::WelcomePage`. Classes in `system/` are top-level.
