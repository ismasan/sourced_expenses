# frozen_string_literal: true

# The stylesheets the layout links (each component's and page's own, see
# web/app.rb): each one, and open pages update when one changes, in
# development. In production, one bundle.
Sidereal.config.config!('sidereal.assets.mode') do
  Sidereal.environment == 'production' ? :combined : :single
end
Sidereal.config.config!('sidereal.assets.live_reload') do
  Sidereal.environment == 'development'
end
