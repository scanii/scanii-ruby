# Changelog

All notable changes to `scanii-ruby` are documented here. Versions follow [SemVer](https://semver.org).

## 1.1.0 — Streaming standardization

Adds stream-based `process` and `process_async` methods, aligning scanii-ruby with the
cross-SDK streaming standard. File content is now truly streamed to the socket via
`Net::HTTP#body_stream=` rather than buffered into a single String.

### New API

- `Scanii::Client#process(io, filename:, content_type: nil, metadata: nil, callback: nil)` →
  `Scanii::ProcessingResult` — accepts any IO-like object (anything responding to `read(n)`).
  Both `File` (opened with `File.open(path, "rb")`) and `StringIO` work.
- `Scanii::Client#process_file(path, metadata: nil, callback: nil)` →
  `Scanii::ProcessingResult` — convenience wrapper that opens the file in binary mode and
  delegates to `process`. This is the replacement for the old `process(path, ...)` form.
- Same shapes for `process_async` / `process_async_file`.

### Deprecations

- `process(path_string, ...)` — passing a String path to `process` is deprecated; use
  `process_file(path)` instead. The old form still works and emits a runtime `warn`. Will be
  removed in a future major version.
- `process_async(path_string, ...)` — same; use `process_async_file(path)`. Will be removed
  in a future major version.

### Internals

- `Scanii::Multipart.stream_encode` replaces the old `encode`. Returns a `[ChainedIO,
  content_type, content_length]` triple. `ChainedIO` reads prologue → caller IO → epilogue
  without ever buffering the full body.

## 1.0.1 — Release infrastructure fix

Wires up `bundler/gem_tasks` in the Rakefile so `bundle exec rake release` (invoked by `rubygems/release-gem@v1`) resolves correctly. v1.0.0 was tagged but never published to RubyGems because the release workflow failed at the `rake release` task lookup; v1.0.1 is functionally identical to that tag. No SDK behavior changes.

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
- **scanii-cli** integration tests cover Linux / macOS / Windows on Ruby 3.4 and 4.0 without burning real Scanii credits. (Ruby 3.5 was preview-only and has no rubyinstaller2 build for Windows.)
- **OIDC trusted publishing** to RubyGems via `rubygems/release-gem` — no long-lived API key in repo secrets.
