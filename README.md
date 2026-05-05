# scanii-ruby

Official Ruby SDK for the [Scanii](https://www.scanii.com) content security API.

[![Gem Version](https://img.shields.io/gem/v/scanii-ruby.svg)](https://rubygems.org/gems/scanii-ruby)

> **Looking for `scanii`?** That gem name is held by an abandoned third-party gem. The official Scanii Ruby SDK is published as **`scanii-ruby`** (matching the [`twilio-ruby`](https://rubygems.org/gems/twilio-ruby) convention).

## SDK Principles

1. **Light.** Zero runtime dependencies, stdlib only.
2. **Up to date.** Always current with the latest Scanii API.
3. **Integration-only.** Wraps the REST API — retries, concurrency, and batching are the caller's responsibility.

## Install

Add to your `Gemfile`:

```ruby
gem "scanii-ruby", "~> 1.0"
```

Or install directly:

```bash
gem install scanii-ruby
```

Targets Ruby 3.4+. Zero runtime dependencies.

## Quickstart

Scan a file from disk:

```ruby
require "scanii"

client = Scanii::Client.new(key: "your-key", secret: "your-secret", endpoint: Scanii::Target::US1)

result = client.process_file("./file.pdf")
puts "findings: #{result.findings.inspect}"
```

Scan content already in memory (no temp file needed):

```ruby
require "stringio"

result = client.process(StringIO.new(bytes), filename: "upload.bin")
puts "findings: #{result.findings.inspect}"
```

`findings` is an `Array<String>`. An empty array means the content is clean.

## API

| Method | REST | Returns |
|---|---|---|
| `process(io, filename:, content_type:, metadata:, callback:)` | `POST /files` | `Scanii::ProcessingResult` |
| `process_file(path, metadata:, callback:)` | `POST /files` | `Scanii::ProcessingResult` |
| `process_async(io, filename:, content_type:, metadata:, callback:)` | `POST /files/async` | `Scanii::PendingResult` |
| `process_async_file(path, metadata:, callback:)` | `POST /files/async` | `Scanii::PendingResult` |
| `process_from_url(location, callback:, metadata:)` | `POST /files` | `Scanii::ProcessingResult` (v2.2 preview) |
| `fetch(url, metadata:, callback:)` | `POST /files/fetch` | `Scanii::PendingResult` |
| `retrieve(id)` | `GET /files/{id}` | `Scanii::ProcessingResult` |
| `retrieve_trace(id)` | `GET /files/{id}/trace` | `Scanii::TraceResult` or `nil` (v2.2 preview) |
| `ping` | `GET /ping` | `true` |
| `create_auth_token(timeout_seconds)` | `POST /auth/tokens` | `Scanii::AuthToken` |
| `retrieve_auth_token(id)` | `GET /auth/tokens/{id}` | `Scanii::AuthToken` |
| `delete_auth_token(id)` | `DELETE /auth/tokens/{id}` | `true` |

Full API reference: <https://scanii.github.io/openapi/v22/>.

## Regional endpoints

```ruby
client = Scanii::Client.new(
  key: "k",
  secret: "s",
  endpoint: Scanii::Target::EU1
)
```

The `endpoint:` keyword accepts either a `Scanii::Target` constant or a bare URL String (useful for scanii-cli, e.g. `endpoint: "http://localhost:4000"`).

| Constant | Endpoint |
|---|---|
| `Scanii::Target::US1` | `https://api-us1.scanii.com` |
| `Scanii::Target::EU1` | `https://api-eu1.scanii.com` |
| `Scanii::Target::EU2` | `https://api-eu2.scanii.com` |
| `Scanii::Target::AP1` | `https://api-ap1.scanii.com` |
| `Scanii::Target::AP2` | `https://api-ap2.scanii.com` |
| `Scanii::Target::CA1` | `https://api-ca1.scanii.com` |
| ~~Auto (default)~~ | ~~`https://api.scanii.com`~~ — **deprecated**, does not guarantee regional data placement |

## Errors

```ruby
require "scanii"

begin
  client.ping
rescue Scanii::AuthError => e
  warn "bad creds: #{e.message} (request_id=#{e.request_id})"
rescue Scanii::RateLimitError => e
  warn "rate-limited; retry after #{e.retry_after}s"
rescue Scanii::Error => e
  warn "other error: #{e.message} (status=#{e.status_code})"
end
```

Error hierarchy:

- `Scanii::Error` — base class, carries `status_code`, `request_id`, `host_id`, `body`
- `Scanii::AuthError` — HTTP 401 / 403
- `Scanii::RateLimitError` — HTTP 429, with `retry_after` (seconds, when the server provided `Retry-After`)

Per SDK Principle 3, the SDK does not retry on the caller's behalf — backoff and retry policy belong to your application.

## Auth tokens

Mint a short-lived token server-side and authenticate with it from a less-trusted client:

```ruby
server_client = Scanii::Client.new(key: "k", secret: "s", endpoint: Scanii::Target::US1)
token = server_client.create_auth_token(300)

token_client = Scanii::Client.new(token: token.id, endpoint: Scanii::Target::US1)
token_client.ping
```

## Local testing with scanii-cli

The SDK ships integration tests against [scanii-cli](https://github.com/scanii/scanii-cli), a local mock server. No real Scanii credentials are needed.

```bash
docker run -d --name scanii-cli -p 4000:4000 ghcr.io/scanii/scanii-cli:latest server

bundle install
bundle exec rake test
```

Test credentials are `key` / `secret`. Override the endpoint by exporting `SCANII_TEST_ENDPOINT=...` before `rake test`. Integration tests self-skip when scanii-cli is not reachable, so `rake test` is safe to run in any environment.

## Contributing

Bug reports and PRs welcome at <https://github.com/scanii/scanii-ruby/issues>.

## License

[Apache-2.0](LICENSE).
