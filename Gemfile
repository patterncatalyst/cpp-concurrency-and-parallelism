source "https://rubygems.org"

# The site deploys via its own `jekyll build` + actions/deploy-pages step
# (see .github/workflows/pages.yml), not GitHub's legacy auto-build, so it
# does not need the `github-pages` meta-gem's strict version pins. Those
# pins (Jekyll 3.9 / Liquid 4.0.3) call Ruby's removed String#tainted? and
# cannot install or run on current Ruby. Plain jekyll + the same plugins
# the meta-gem bundled gives the same output without the pin.
gem "jekyll", "~> 4.3"

# Ruby 3.4+ dropped these from the default gems; jekyll still needs them.
gem "csv"        # Jekyll::Utils and liquid-tag CSV parsing
gem "bigdecimal"  # transitive dep of jekyll-sass-converter's protobuf backend
gem "base64"      # used by jekyll core for asset/content hashing
gem "logger"      # used by jekyll's own logger and the listen gem (serve mode)

# Ruby 3.0+ dropped the bundled HTTP server; `jekyll serve` needs it explicitly.
gem "webrick"

# Keep this group in exact sync with the `plugins:` list in _config.yml —
# do not add plugins the site doesn't declare/use there.
group :jekyll_plugins do
  gem "jekyll-seo-tag"
  gem "jekyll-sitemap"
  gem "jekyll-redirect-from"
end

# Performance booster on Linux/macOS local dev
gem "wdm", "~> 0.1.1", :install_if => Gem.win_platform?

# Lock http_parser.rb to v0.6.x on JRuby; otherwise no-op.
gem "http_parser.rb", "~> 0.6.0", :platforms => [:jruby]
