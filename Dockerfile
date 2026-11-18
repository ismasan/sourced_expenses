# syntax=docker/dockerfile:1
#
# The app in one image: Falcon serving it on port 9292, its SQLite database
# and uploads in /app/storage (mount a volume there to keep them).
#
#   docker build -t sourced-expenses .
#   docker run --rm -p 9292:9292 --env-file .env -v sourced-expenses:/app/storage sourced-expenses
#
# Secrets (OPENAI_API_KEY, or another LLM provider's) come from the environment at run time, never
# from the image: .dockerignore leaves .env out of the build.

ARG RUBY_VERSION=4.0.5

# ---- Gems: built here, with the compilers and git (for the GitHub gems) ----
FROM ruby:${RUBY_VERSION}-slim AS gems

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential git libssl-dev libyaml-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 \
 && rm -rf "$BUNDLE_PATH"/ruby/*/cache "$BUNDLE_PATH"/ruby/*/bundler/gems/*/.git

# ---- The app: Ruby, the gems, and what it shells out to ----
FROM ruby:${RUBY_VERSION}-slim

# ImageMagick shrinks photos and draws thumbnails; Ghostscript lets it read
# PDFs, which Debian's ImageMagick policy refuses until allowed below.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends imagemagick ghostscript \
 && rm -rf /var/lib/apt/lists/* \
 && for policy in /etc/ImageMagick-*/policy.xml; do \
      sed -i 's/rights="none" pattern="PDF"/rights="read" pattern="PDF"/' "$policy"; \
    done

WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    HOST=0.0.0.0 \
    PORT=9292

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY . .

# Not root: the app only writes to storage/.
RUN useradd --create-home --uid 1000 app \
 && mkdir -p storage \
 && chown -R app:app storage
USER app

VOLUME /app/storage
EXPOSE 9292

# Migrates the database (creating it on the first run), then starts Falcon.
ENTRYPOINT ["bin/docker-entrypoint"]
CMD ["bundle", "exec", "falcon", "host"]
