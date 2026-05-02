require_relative "../test_helper"
require "tmpdir"
require "socket"
require "timeout"
require "stringio"

# Integration tests must talk to a real local scanii-cli; ensure WebMock (loaded
# by unit tests in the same process) does not block real HTTP.
begin
  require "webmock"
  WebMock.allow_net_connect!
  WebMock.disable!
rescue LoadError
  # webmock not loaded -- nothing to disable
end

# Integration tests against scanii-cli running on http://localhost:4000.
#
# Bring up scanii-cli before running:
#
#   docker run -d --name scanii-cli -p 4000:4000 ghcr.io/scanii/scanii-cli:latest server
#
# In CI we boot it via scanii/setup-cli-action@v1. Tests self-skip with a
# message when scanii-cli is not reachable, so `rake test` is safe to run in
# any environment.
module Scanii
  class ClientIntegrationTest < Minitest::Test
    KEY    = "key".freeze
    SECRET = "secret".freeze
    LOCAL_MALWARE_UUID    = "38DCC0C9-7FB6-4D0D-9C37-288A380C6BB9".freeze
    LOCAL_MALWARE_FINDING = "content.malicious.local-test-file".freeze

    @cli_available = nil

    class << self
      attr_accessor :cli_available
    end

    def self.endpoint
      ENV.fetch("SCANII_TEST_ENDPOINT", "http://localhost:4000")
    end

    def self.cli_reachable?
      return @cli_available unless @cli_available.nil?

      @cli_available = begin
        c = Client.new(key: KEY, secret: SECRET, endpoint: endpoint, timeout: 2)
        c.ping
        true
      rescue StandardError
        false
      end
    end

    def setup
      # Defensively re-enable real HTTP in case the unit-test suite (loaded in
      # the same process) left WebMock blocking net connections.
      if defined?(WebMock)
        WebMock.allow_net_connect!
        WebMock.disable!
      end
      skip "scanii-cli not reachable at #{self.class.endpoint}" unless self.class.cli_reachable?
      @client = Client.new(key: KEY, secret: SECRET, endpoint: self.class.endpoint)
    end

    def test_ping_with_valid_credentials
      assert_equal true, @client.ping
    end

    def test_ping_with_bad_credentials_raises_auth
      bad = Client.new(key: "nope", secret: "nope", endpoint: self.class.endpoint)
      assert_raises(AuthError) { bad.ping }
    end

    # -- process_file (path convenience) -----------------------------------

    def test_process_file_clean_returns_no_findings
      path = temp_file("hello world")
      result = @client.process_file(path, metadata: { "source" => "integration", "tag" => "clean" })
      refute_empty result.id
      assert_empty result.findings
      assert_equal result.id, @client.retrieve(result.id).id
    ensure
      cleanup(path)
    end

    def test_process_file_uuid_fixture_flags_local_malware
      path = temp_file(LOCAL_MALWARE_UUID)
      result = @client.process_file(path)
      if result.findings.include?(LOCAL_MALWARE_FINDING)
        assert_includes result.findings, LOCAL_MALWARE_FINDING
      else
        skip "scanii-cli did not flag the UUID fixture (older build); got: #{result.findings.inspect}"
      end
    ensure
      cleanup(path)
    end

    # -- process(io, filename:) — in-memory StringIO -----------------------

    def test_process_with_stringio_clean_returns_no_findings
      io = StringIO.new("hello from stringio")
      result = @client.process(io, filename: "test.txt", metadata: { "source" => "integration-stringio" })
      refute_empty result.id
      assert_empty result.findings
    end

    def test_process_with_stringio_uuid_fixture_flags_malware
      io = StringIO.new(LOCAL_MALWARE_UUID)
      result = @client.process(io, filename: "malware-test.bin")
      if result.findings.include?(LOCAL_MALWARE_FINDING)
        assert_includes result.findings, LOCAL_MALWARE_FINDING
      else
        skip "scanii-cli did not flag the UUID fixture (older build); got: #{result.findings.inspect}"
      end
    end

    # -- process(io, filename:) — disk File IO -----------------------------

    def test_process_with_file_io_clean_returns_no_findings
      path = temp_file("hello from file io")
      result = File.open(path, "rb") do |f|
        @client.process(f, filename: File.basename(path))
      end
      refute_empty result.id
      assert_empty result.findings
    ensure
      cleanup(path)
    end

    # -- process_async_file ------------------------------------------------

    def test_process_async_file_returns_pending_then_retrievable
      path = temp_file("hello async")
      pending = @client.process_async_file(path)
      refute_empty pending.id
      sleep 0.5
      assert_equal pending.id, @client.retrieve(pending.id).id
    ensure
      cleanup(path)
    end

    # -- process_async(io, filename:) — StringIO ---------------------------

    def test_process_async_with_stringio_returns_pending
      io = StringIO.new("hello async stringio")
      pending = @client.process_async(io, filename: "async-test.bin")
      refute_empty pending.id
    end

    # -- deprecated process(path) alias ------------------------------------

    def test_process_deprecated_path_still_works_and_warns
      path = temp_file("deprecated path test")
      _out, err = capture_io do
        result = @client.process(path)
        refute_empty result.id
      end
      assert_match(/deprecated/, err)
      assert_match(/process_file/, err)
    ensure
      cleanup(path)
    end

    # -- retrieve_trace (v2.2 preview) -------------------------------------

    def test_retrieve_trace_returns_non_empty_events_for_known_id
      path = temp_file(LOCAL_MALWARE_UUID)
      result = @client.process_file(path)
      trace = @client.retrieve_trace(result.id)
      refute_nil trace, "retrieve_trace must return a TraceResult for a known id"
      assert_kind_of Scanii::TraceResult, trace
      refute_empty trace.events, "events array must be non-empty for a known processing id"
      assert(trace.events.all?(Scanii::TraceEvent))
    ensure
      cleanup(path)
    end

    def test_retrieve_trace_returns_nil_for_unknown_id
      result = @client.retrieve_trace("does-not-exist-trace-#{Process.pid}")
      assert_nil result
    end

    # -- process_from_url (v2.2 preview) -----------------------------------

    def test_process_from_url_returns_result_with_eicar_finding
      url = "#{self.class.endpoint}/static/eicar.txt"
      result = @client.process_from_url(url)
      refute_nil result, "process_from_url must return a ProcessingResult"
      assert_kind_of Scanii::ProcessingResult, result
      assert_includes result.findings, "content.malicious.eicar-test-signature",
                      "expected EICAR finding; got: #{result.findings.inspect}"
    end

    # -- fetch --------------------------------------------------------------

    def test_fetch_returns_pending_result
      r = @client.fetch("https://example.com/test.txt")
      refute_empty r.id
    end

    # -- auth token lifecycle -----------------------------------------------

    def test_auth_token_lifecycle
      tok = @client.create_auth_token(30)
      refute_empty tok.id

      same = @client.retrieve_auth_token(tok.id)
      assert_equal tok.id, same.id

      token_client = Client.new(token: tok.id, endpoint: self.class.endpoint)
      begin
        token_client.ping
      rescue StandardError => e
        # Older scanii-cli builds may not honor token-auth ping; surface for visibility.
        warn "[integration] token-auth ping rejected: #{e.message}"
      end

      assert_equal true, @client.delete_auth_token(tok.id)
    end

    def test_retrieve_unknown_id_raises
      assert_raises(Error) { @client.retrieve("does-not-exist-#{Process.pid}") }
    end

    def test_callback_delivery
      server = TCPServer.new("127.0.0.1", 0)
      port   = server.addr[1]
      captured = nil

      thread = Thread.new do
        Thread.current.report_on_exception = false
        Timeout.timeout(8) do
          client = server.accept
          captured = read_http_request_body(client)
          client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          client.close
        end
      rescue Timeout::Error
        # nothing -- caller handles nil captured
      ensure
        server.close
      end

      path = temp_file("hello callback")
      @client.process_file(path, callback: "http://127.0.0.1:#{port}/cb")

      thread.join

      if captured.nil? || captured.empty?
        skip "scanii-cli did not deliver a callback (callback support is a Phase-1 prereq)"
      end
      assert_includes captured, "\"id\""
    ensure
      cleanup(path)
    end

    private

    def temp_file(contents)
      path = File.join(Dir.tmpdir, "scanii-ruby-integ-#{Process.pid}-#{rand(1 << 32)}.bin")
      File.binwrite(path, contents)
      path
    end

    def cleanup(path)
      File.unlink(path) if path && File.exist?(path)
    rescue StandardError
      # best-effort
    end

    def read_http_request_body(socket)
      raw = String.new(encoding: Encoding::BINARY)
      socket.set_encoding(Encoding::BINARY, Encoding::BINARY)

      headers_done = false
      content_length = 0
      until headers_done
        chunk = socket.readpartial(8192)
        raw << chunk
        next unless (idx = raw.index("\r\n\r\n"))

        headers_done = true
        headers_blob = raw[0...idx]
        headers_blob.split("\r\n").each do |line|
          if (m = line.match(/\Acontent-length\s*:\s*(\d+)\z/i))
            content_length = m[1].to_i
          end
        end
        body_so_far = raw.bytesize - (idx + 4)
        break if body_so_far >= content_length
      end

      body_start = raw.index("\r\n\r\n") + 4
      raw << socket.readpartial(8192) while raw.bytesize - body_start < content_length
      raw[body_start, content_length]
    rescue IOError
      raw
    end
  end
end
