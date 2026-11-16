# frozen_string_literal: true

source 'https://rubygems.org'

gem 'sidereal', github: 'ismasan/sidereal'
# gem 'sidereal', path: '../../gems/sidereal'
gem 'sourced', github: 'ismasan/sourced'
# gem 'sourced', path: '../../gems/sourced'
# The Sourced dashboard, mounted at /sourced in config.ru.
gem 'sourced-ui', github: 'ismasan/sourced-ui'
# gem 'sourced-ui', path: '../../gems/sourced-ui'
gem 'falcon'
# Reads the uploads (system/expenses/scanner.rb). See config/components/llm.rb.
gem 'ruby_llm'
# Loads .env into ENV in development. See boot.rb.
gem 'dotenv'
gem 'zeitwerk'

group :development do
  gem 'irb'
end

group :test do
  gem 'rack-test'
  gem 'rspec'
end

# The app's database. See config/components/db.rb.
gem 'sequel'
gem 'sqlite3'
