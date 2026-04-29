require_relative "lib/scanii/version"

Gem::Specification.new do |spec|
  spec.name          = "scanii-ruby"
  spec.version       = Scanii::VERSION
  spec.authors       = ["Scanii"]
  spec.summary       = "Zero-dependency Ruby SDK for the Scanii content security API"
  spec.description   = "Ruby client for Scanii (scanii.com). Stdlib only -- no runtime dependencies."
  spec.homepage      = "https://github.com/scanii/scanii-ruby"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata = {
    "homepage_uri" => "https://scanii.com",
    "source_code_uri" => "https://github.com/scanii/scanii-ruby",
    "documentation_uri" => "https://scanii.github.io/openapi/v22/",
    "changelog_uri" => "https://github.com/scanii/scanii-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files         = Dir["lib/**/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5"
  spec.add_development_dependency "rake", "~> 13"
  spec.add_development_dependency "rubocop", "~> 1"
  spec.add_development_dependency "webmock", "~> 3"
  # NO runtime dependencies.
end
