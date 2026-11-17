# Sourced Expenses

A [Sidereal](https://github.com/ismasan/sidereal) + [Sourced](https://github.com/ismasan/sourced) app that tracks expenses from scanned receipts and invoices, after [this write-up](https://gist.github.com/julik/405662cc3106fe73ae2e46073f483b62). Uploads are scanned with OpenAI and listed on the home page as they go; there's no review form yet.



https://github.com/user-attachments/assets/f7cdf4bd-398e-4f86-91e8-ebcdb6a1345f



## Expenses

`Expenses::Expense` (`system/expenses/`) is one machine per uploaded document: `UploadDocument` → `scanning` → `reviewing` → `SaveExpense` → `filed`.

- `Expense::Scanning` is the OCR pipeline. Each LLM call is a state (`extracting`, `verifying`, `rechecking_date`, `cleaning`) waiting for its worker's `Complete…` or `Fail…`. The decisions between them are transient states with guards (`checking_extraction`, `checking_date`) over plain Ruby in `Expenses::Document`.
- A failed date recheck or cleanup keeps the first reading. A failed preparation, extraction or verification fails the scan, and so does the `after` timer (`SCAN_TIMEOUT`, default `10m`). From there a person can rescan or fill in the form by hand.
- `Expense::Filed` holds the VAT treatment: inferred by rule (never by the model), flagged for review when it's foreign VAT, and kept for good once a person confirms one. Corrections are saved in place.

`Expenses::Scanner` is the worker for scanning: when an expense enters one of its waiting states, it does that step (`Expenses::ScanSteps`, with the write-up's prompts in `Expenses::Prompts`) and reports back with the step's `Complete…` or `Fail…`. It's a consumer group of its own, so a model call never holds up the machine, and turns what a step can expect to go wrong (the model, the image, a missing file, an answer that doesn't fit) into `Fail…` with a reason safe to show. Images over 500 KB are shrunk with ImageMagick first. `Expenses::Submissions` is the read model the home page lists, and the list re-renders whenever it commits.

`Expenses::CurrencyConverter` converts each filed expense's total (VAT included) to the reporting currency at the European Central Bank's rate for its date, from the [Frankfurter API](https://frankfurter.dev), and records it on the expense (`ConversionRecorded`, or `ConversionFailed` with a reason), saying which currency it converted to. The reporting currency is `REPORTING_CURRENCY`, `GBP` by default. Expenses already in it are left alone. A correction to the amount, currency or date converts again. It's a consumer group of its own too, and on a store with expenses already filed it catches up on them when it first starts.

`Expenses::Ledger` is the read model for totals in the reporting currency: one row per filed expense (table `ledger`), with its conversion once recorded and the currency it's in. A correction to the total clears the conversion until it's converted again; voided expenses leave it. `Ledger.month(db, currency, date)` totals a month in `currency` by the expenses' own dates: expenses in that currency count as they are, those converted to it count converted, and it says how many aren't in it yet. The All expenses page shows this month's. Each row has the expense's category too (the suggestion until a person chooses), so totals, and the page's header and chart, can be of the categories ticked; the ledger is event-sourced, since a category can be suggested before there's a row.

`Expenses::Categorizer` suggests each expense's accounting category, one of `Expenses::CATEGORIES` (`system/expenses.rb`), modelled on the default expense categories of UK bookkeeping apps such as FreeAgent and Xero. It asks once the scan is done, and again when the expense is filed with a description it hasn't asked about (an expense filled in by hand, or a corrected description). The question is a [RubyLLM judgment](https://rubyllm.com/judgments/) (`Expenses::CategoryJudge`) over what was read and filed (description, supplier, VAT description, total), not the document itself, and the answer comes back with how likely the model thinks it is. The machine records it on the expense (`CategorySuggested`, or `CategorizationFailed` with a reason) in review or filed. It's only a suggestion: a person chooses a category on the submission page (`ChooseCategory`), and a choice is never replaced by a suggestion. It's a consumer group of its own too, so on a store with expenses already in it, it categorizes those when it first starts. `bin/sid sourced groups reset expenses.categorizer` tries again the ones that failed or never got one; ones with a suggestion are left alone.

Changing `REPORTING_CURRENCY` on a store with expenses converted already: `bin/sid sourced groups reset expenses.currency_converter` converts them again. Until then they count as not converted; the ledger needs no reset.

Uploads land in `FileStore::Disk` (`storage/uploads/`), by the MD5 of their bytes, and the expense's id is that same digest (`Types::ExpenseID`). So the same file is the same expense: uploading it again, from the form or `bin/sid expenses upload`, goes to the expense it already is and dispatches nothing. Only identical bytes match; the same invoice downloaded twice may not be identical.

`Sourced::Machine::Mermaid.new(Expenses::Expense).to_s` draws the chart. The Sourced dashboard is mounted at `/sourced`.

Message attributes use the app's `Types` (`system/types.rb`, Sourced's types): `Types::String.present`, `Types::Boolean`. Plain scalars are Ruby's own classes: `String`, `Integer`, `Date`.

## Run

```sh
bundle install
bin/sid db migrations run
bin/dev
```

Scanning needs `OPENAI_API_KEY`, from the environment or `.env` (never committed), and ImageMagick's `magick` (`brew install imagemagick`). `OPENAI_MODEL` picks another model than `gpt-4.1`. Categories are judged by `OPENAI_JUDGMENT_MODEL`, `gpt-6-luna` by default: it has to be a model OpenAI answers judgments with. Specs fake the model and never call OpenAI. Exchange rates need no key; `EXCHANGE_RATES_URL` points at another Frankfurter instance, and specs fake them too. `REPORTING_CURRENCY` (an ISO code, `GBP` by default) is the currency totals are in, and `FILING_COUNTRY` (`GB` by default) the country whose books these are, which decides each expense's VAT treatment.

Then open <http://localhost:9292>. `PORT`, `HOST` and `COUNT` (worker processes) can be set in the environment.

The migrations in `db/migrations/` are committed and `storage/` isn't, so `bin/sid db migrations run` is how a checkout gets its database — copy one over instead if you'd rather keep the data.

`bin/dev` runs `bundle exec falcon host` and reloads the app whenever a Ruby file changes. Reloading needs a file watcher: [watchexec](https://github.com/watchexec/watchexec) (`brew install watchexec`) or fswatch. Without one, the server still runs. In production, run `bundle exec falcon host`.

## Docker

The `Dockerfile` builds the app with everything it shells out to (ImageMagick, and Ghostscript for PDFs), for Intel or ARM:

```sh
docker build -t sourced-expenses .
docker run --rm -p 9292:9292 --env-file .env -v sourced-expenses:/app/storage sourced-expenses
```

`OPENAI_API_KEY` comes from the environment at run time (`--env-file .env`, or `-e OPENAI_API_KEY=…`); the image never contains `.env`. The database and uploads live in `/app/storage`, so the named volume keeps them between runs, and each start runs any migrations not run yet (`bin/docker-entrypoint`). `COUNT` sets the worker processes, as with `bin/dev`. Docker's env files take values as written, so leave them unquoted.

## Test

```sh
bundle exec rspec
```

## Database

The `db` component in `config/components/db.rb` is a SQLite database under `storage/` (`storage/db.db`), which classes reach with `dep :db`. Migrations are [Sequel](https://sequel.jeremyevans.net/rdoc/files/doc/migration_rdoc.html)'s:

```sh
bin/sid db migrations add create_things   # writes db/migrations/<timestamp>_create_things.rb
bin/sid db migrations run                 # the ones not run yet
bin/sid db migrations rollback            # just the one that ran last
```

Sourced keeps the app's commands and events in the same database, in tables its own migration creates (`db/migrations/20261011220710_create_sourced_tables.rb`, written by `bin/sid sourced migration`).

## Command line

`bin/sid` is Sidereal's command line with this app loaded. `bin/sid --help` lists every command; the ones worth knowing:

```sh
bin/sid console                                   # IRB with the app loaded
bin/sid commands list                             # the commands the app handles
bin/sid commands info expenses.save_expense       # a command's payload schema
bin/sid commands dispatch <Command> --attr value  # send one
bin/sid sourced topology                          # how commands, events, read models and automations connect
bin/sid sourced messages list --tail              # the store's messages, as they arrive
bin/sid sourced messages correlation <id>         # the causal tree a message belongs to
bin/sid sourced groups list                       # consumer groups (expenses.scanner, expenses.categorizer…) and their status
bin/sid sourced groups start <group>              # restart a failed one
bin/sid system graph                              # the app's components and their dependencies
bin/sid expenses upload ~/receipts/*.pdf          # upload documents to scan, as the upload form does
bin/sid expenses list --state filed --json        # expenses, filtered: a table, or JSON lines
bin/sid expenses dispatch <Command>               # a command for each JSON line on stdin
```

`bin/sid expenses list` filters the list the app shows (`--state`, `--category`, `--category-status suggested|chosen|none`, `--from`, `--to`, `--limit`), and with `--json` prints one object per line. `bin/sid expenses dispatch` sends a command for each line it's piped, taking the payload from the fields the command has, with attributes given as `bin/sid commands dispatch` takes them winning over the lines'. Every command is checked first and nothing is sent if any is invalid; `--dry-run` lists them instead. Confirming every filed expense's suggested category:

```sh
bin/sid expenses list --state filed,vat_needs_review --category-status suggested --json |
  bin/sid expenses dispatch expenses.choose_category
```

Or recategorizing the general ones: `bin/sid expenses list --category general --json | bin/sid expenses dispatch expenses.choose_category --category office_costs`. Filter with `jq` in between for anything `list` doesn't.

`bin/sid expenses upload` takes PDFs and photos (JPEG, PNG or WebP, by extension) up to 20 MB, as the form does. It stores each one, dispatches its `UploadDocument` and prints the page to watch it scan ("Already uploaded" for a file it has seen, dispatching nothing); a file it can't take is skipped, and the exit status says so. `--reference-date YYYY-MM-DD` reads the documents' dates against another day than today. The running app does the scanning: without it, uploads wait in the store. The app's own commands live in `cli/`, registered by `config/components/cli.rb` only when `bin/sid` runs.

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
| `cli/` | The app's own `bin/sid` commands (`bin/sid expenses …`) |
| `db/migrations/` | Database migrations, run with `bin/sid db migrations run`. Add one with `bin/sid db migrations add <name>` |
| `storage/` | Runtime data, including the SQLite database. Not committed. |
| `falcon.rb` | Falcon server settings |
| `bin/dev` | Development server that reloads on code changes |
| `bin/sid` | Sidereal's command line with this app loaded. `bin/sid --help` lists its commands |
| `.agents/skills/` | Skills that teach AI coding agents to work with this app, such as using `bin/sid`. `.claude/skills` links here. `bin/sid skills update` refreshes the ones Sidereal and its integrations provide |

Classes in `system/` and `web/` are loaded by [Zeitwerk](https://github.com/fxn/zeitwerk): name a file after the class it defines and use the class anywhere, without `require`. Directories under `web/` are namespaces, so `web/ui/welcome_page.rb` defines `UI::WelcomePage`. Classes in `system/` are top-level.
