Gem::Specification.new do |spec|
  spec.name        = "sequel-ractor"
  spec.version     = "0.0.1"
  spec.authors     = ["Andrew Zhuk"]
  spec.summary     = "Ractor compatibility shim for Sequel"
  spec.description = "Monkey-patches Sequel so its core operations " \
                     "(Sequel.connect, Database.new, model definition) work " \
                     "from within non-main Ractor contexts on Ruby 3.2+. " \
                     "Targets Sequel 5.x. Does not require any change to " \
                     "Sequel itself — load this gem after sequel and " \
                     "call SequelRactor.finalize! once at boot. " \
                     "Trade-offs and limitations documented in README."
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/andrewzhuk/sequel-ractor"

  spec.required_ruby_version = ">= 3.2"
  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sequel", ">= 5.84", "< 6"

  # homepage_uri is auto-derived from spec.homepage. Don't duplicate.
  spec.metadata = {
    "source_code_uri"       => spec.homepage,
    "bug_tracker_uri"       => "#{spec.homepage}/issues",
    "changelog_uri"         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
  }
end
