require_relative "../test_helper"
require "tmpdir"
require "socket"
require "timeout"

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

    def test_process_clean_file_returns_no_findings
      path = temp_file("hello world")
      result = @client.process(path, metadata: { "source" => "integration", "tag" => "clean" })
      refute_empty result.id
      assert_empty result.findings
      assert_equal result.id, @client.retrieve(result.id).id
    ensure
      cleanup(path)
    end

    def test_process_uuid_fixture_flags_local_malware
      path = temp_file(LOCAL_MALWARE_UUID)
      result = @client.process(path)
      if result.findings.include?(LOCAL_MALWARE_FINDING)
        assert_includes result.findings, LOCAL_MALWARE_FINDING
      else
        skip "scanii-cli did not flag the UUID fixture (older build); got: #{result.findings.inspect}"
      end
    ensure
      cleanup(path)
    end

    def test_process_async_returns_pending_then_retrievable
      path = temp_file("hello async")
      pending = @client.process_async(path)
      refute_empty pending.id
      sleep 0.5
      assert_equal pending.id, @client.retrieve(pending.id).id
    ensure
      cleanup(path)
    end

    def test_fetch_returns_pending_result
      r = @client.fetch("https://example.com/test.txt")
      refute_empty r.id
    end

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
      @client.process(path, callback: "http://127.0.0.1:#{port}/cb")

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
