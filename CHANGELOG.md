# Changelog

All notable changes to `scanii-ruby` are documented here. Versions follow [SemVer](https://semver.org).

## 1.0.0 — Initial release

First public release of the Scanii Ruby SDK on RubyGems as `scanii-ruby` (the plain `scanii` gem name is held by an abandoned third-party gem; this SDK uses the `scanii-ruby` convention matching `twilio-ruby`). Supersedes the `scanii-ruby 0.0.1` namespace-reservation placeholder.

Reference implementation frozen at scanii-java v8.0.0.

### API surface

- `Scanii::Client#process(file_path, metadata:, callback:)` → `Scanii::ProcessingResult`
- `Scanii::Client#process_async(file_path, metadata:, callback:)` → `Scanii::PendingResult`
- `Scanii::Client#fetch(url, metadata:, callback:)` → `Scanii::PendingResult`
- `Scanii::Client#retrieve(id)` → `Scanii::ProcessingResult`
- `Scanii::Client#ping` → `true`
- `Scanii::Client#create_auth_token(timeout_seconds)` → `Scanii::AuthToken`
- `Scanii::Client#retrieve_auth_token(id)` → `Scanii::AuthToken`
- `Scanii::Client#delete_auth_token(id)` → `true`

Errors: `Scanii::Error` (base), `Scanii::AuthError` (401/403), `Scanii::RateLimitError` (429, with `retry_after`).

### Highlights

- **Zero runtime dependencies.** Stdlib `net/http` + `json` + `securerandom` + `base64` only.
- **Hand-rolled multipart/form-data encoder** (no `multipart-post`, no `rack-mime`).
- **Synchronous.** Single-threaded by default; create one `Scanii::Client` per thread.
- **Targets Ruby 3.4+.**
- **scanii-cli** integration tests cover Linux / macOS / Windows on Ruby 3.5 and 4.0 (current + previous stable) without burning real Scanii credits.
- **OIDC trusted publishing** to RubyGems via `rubygems/release-gem` — no long-lived API key in repo secrets.
