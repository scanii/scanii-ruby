require_relative "../test_helper"
require "webmock/minitest"
require "tmpdir"
require "stringio"

module Scanii
  class ClientUnitTest < Minitest::Test
    KEY    = "key".freeze
    SECRET = "secret".freeze
    BASE   = "http://example.test/v2.2".freeze

    def setup
      WebMock.enable!
      WebMock.reset!
      WebMock.disable_net_connect!
      @client = Client.new(key: KEY, secret: SECRET, endpoint: "http://example.test")
    end

    def teardown
      WebMock.reset!
    end

    # -- Constructor / auth -----------------------------------------------

    def test_rejects_empty_key
      assert_raises(ArgumentError) { Client.new(key: "", secret: "s") }
    end

    def test_rejects_colon_in_key
      assert_raises(ArgumentError) { Client.new(key: "a:b", secret: "s") }
    end

    def test_rejects_missing_secret
      assert_raises(ArgumentError) { Client.new(key: "k") }
    end

    def test_rejects_token_plus_key
      assert_raises(ArgumentError) { Client.new(token: "t", key: "k", secret: "s") }
    end

    def test_token_only_succeeds
      Client.new(token: "tok") # no raise
    end

    def test_rejects_non_http_endpoint
      assert_raises(ArgumentError) { Client.new(key: "k", secret: "s", endpoint: "ftp://nope.example") }
    end

    def test_user_agent_header_default
      stub = stub_request(:get, "#{BASE}/ping")
             .with(headers: { "User-Agent" => "scanii-ruby/#{VERSION}" })
             .to_return(status: 200, body: "")
      assert @client.ping
      assert_requested(stub)
    end

    def test_user_agent_header_custom_prefix
      client = Client.new(key: KEY, secret: SECRET, endpoint: "http://example.test", user_agent: "my-app/1.0")
      stub = stub_request(:get, "#{BASE}/ping")
             .with(headers: { "User-Agent" => "my-app/1.0 scanii-ruby/#{VERSION}" })
             .to_return(status: 200, body: "")
      assert client.ping
      assert_requested(stub)
    end

    def test_authorization_header_basic
      expected = "Basic #{["#{KEY}:#{SECRET}"].pack("m0")}"
      stub = stub_request(:get, "#{BASE}/ping")
             .with(headers: { "Authorization" => expected })
             .to_return(status: 200, body: "")
      assert @client.ping
      assert_requested(stub)
    end

    def test_authorization_header_with_token
      token_client = Client.new(token: "abc", endpoint: "http://example.test")
      expected = "Basic #{["abc:"].pack("m0")}"
      stub = stub_request(:get, "#{BASE}/ping")
             .with(headers: { "Authorization" => expected })
             .to_return(status: 200, body: "")
      assert token_client.ping
      assert_requested(stub)
    end

    # -- ping ---------------------------------------------------------------

    def test_ping_returns_true_on_200
      stub_request(:get, "#{BASE}/ping").to_return(status: 200, body: '{"message":"pong"}')
      assert_equal true, @client.ping
    end

    def test_ping_raises_auth_on_401
      stub_request(:get, "#{BASE}/ping").to_return(status: 401, body: '{"error":"bad creds"}')
      err = assert_raises(AuthError) { @client.ping }
      assert_equal 401, err.status_code
      assert_equal "bad creds", err.message
    end

    def test_ping_raises_rate_limit_on_429_with_retry_after
      stub_request(:get, "#{BASE}/ping").to_return(
        status: 429,
        body: '{"error":"slow down"}',
        headers: { "Retry-After" => "12" }
      )
      err = assert_raises(RateLimitError) { @client.ping }
      assert_equal 12, err.retry_after
      assert_equal "slow down", err.message
    end

    def test_error_captures_request_id
      stub_request(:get, "#{BASE}/ping").to_return(
        status: 500,
        body: '{"error":"boom"}',
        headers: { "X-Scanii-Request-Id" => "req-123" }
      )
      err = assert_raises(Error) { @client.ping }
      assert_equal "req-123", err.request_id
    end

    # -- process(io, filename:) — stream-based canonical method --------

    def test_process_with_stringio_returns_processing_result
      io = StringIO.new("hello world")
      response_body = JSON.generate(
        "id" => "abc",
        "findings" => [],
        "checksum" => "sha1",
        "content_length" => 11,
        "content_type" => "text/plain",
        "metadata" => { "source" => "unit" },
        "creation_date" => "2026-04-29T00:00:00Z"
      )
      stub_request(:post, "#{BASE}/files").to_return(
        status: 201,
        body: response_body,
        headers: { "X-Scanii-Request-Id" => "req-1", "Location" => "/v2.2/files/abc" }
      )
      result = @client.process(io, filename: "hello.txt", metadata: { "source" => "unit" })
      assert_kind_of ProcessingResult, result
      assert_equal "abc", result.id
      assert_equal [], result.findings
      assert_equal 11, result.content_length
      assert_equal "req-1", result.request_id
      assert_equal "/v2.2/files/abc", result.resource_location
    end

    def test_process_with_file_io_sends_correct_body
      file = make_temp_file("hello mp")
      stub = stub_request(:post, "#{BASE}/files")
             .with do |req|
               ct = req.headers["Content-Type"]
               body = req.body
               ct.start_with?("multipart/form-data; boundary=") &&
                 body.include?("hello mp") &&
                 body.include?(%(name="metadata[source]")) &&
                 body.include?(%(name="callback")) &&
                 body.include?("https://cb.example/x") &&
                 body.include?(%(name="file"; filename=))
             end
             .to_return(status: 201, body: '{"id":"abc","findings":[]}')
      File.open(file, "rb") do |f|
        @client.process(f, filename: File.basename(file),
                           metadata: { "source" => "u" }, callback: "https://cb.example/x")
      end
      assert_requested(stub)
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    def test_process_requires_filename_keyword
      io = StringIO.new("data")
      assert_raises(ArgumentError) { @client.process(io) }
    end

    def test_process_raises_for_non_io_non_string
      assert_raises(ArgumentError) { @client.process(42, filename: "f.bin") }
    end

    # -- process_file — path convenience -----------------------------------

    def test_process_file_returns_processing_result
      file = make_temp_file("hello world")
      response_body = JSON.generate(
        "id" => "abc",
        "findings" => [],
        "checksum" => "sha1",
        "content_length" => 11,
        "content_type" => "text/plain",
        "metadata" => { "source" => "unit" },
        "creation_date" => "2026-04-29T00:00:00Z"
      )
      stub_request(:post, "#{BASE}/files").to_return(
        status: 201,
        body: response_body,
        headers: { "X-Scanii-Request-Id" => "req-1", "Location" => "/v2.2/files/abc" }
      )
      result = @client.process_file(file, metadata: { "source" => "unit" })
      assert_kind_of ProcessingResult, result
      assert_equal "abc", result.id
      assert_equal [], result.findings
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    def test_process_file_sends_multipart_body
      file = make_temp_file("hello mp")
      stub = stub_request(:post, "#{BASE}/files")
             .with do |req|
               ct = req.headers["Content-Type"]
               body = req.body
               ct.start_with?("multipart/form-data; boundary=") &&
                 body.include?("hello mp") &&
                 body.include?(%(name="metadata[source]")) &&
                 body.include?(%(name="callback")) &&
                 body.include?("https://cb.example/x") &&
                 body.include?(%(name="file"; filename=))
             end
             .to_return(status: 201, body: '{"id":"abc","findings":[]}')
      @client.process_file(file, metadata: { "source" => "u" }, callback: "https://cb.example/x")
      assert_requested(stub)
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    def test_process_file_raises_for_unreadable_path
      assert_raises(ArgumentError) { @client.process_file("/no/such/file/scanii-ruby-unit-test.bin") }
    end

    # -- deprecated process(path) alias ------------------------------------

    def test_process_path_deprecated_still_works
      file = make_temp_file("hello deprecation")
      stub_request(:post, "#{BASE}/files").to_return(
        status: 201,
        body: '{"id":"dep","findings":[]}'
      )
      _out, err = capture_io { @client.process(file) }
      assert_match(/deprecated/, err)
      assert_match(/process_file/, err)
      assert_match(/future major version/, err)
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    def test_process_path_deprecated_passes_metadata_and_callback
      file = make_temp_file("meta test")
      stub = stub_request(:post, "#{BASE}/files")
             .with { |req| req.body.include?(%(name="metadata[k]")) && req.body.include?("v") }
             .to_return(status: 201, body: '{"id":"x","findings":[]}')
      capture_io { @client.process(file, metadata: { "k" => "v" }) }
      assert_requested(stub)
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    # -- process_async(io, filename:) / process_async_file -----------------

    def test_process_async_with_stringio_expects_202
      io = StringIO.new("async content")
      stub_request(:post, "#{BASE}/files/async").to_return(
        status: 202,
        body: '{"id":"pending-1"}',
        headers: { "Location" => "/v2.2/files/pending-1" }
      )
      r = @client.process_async(io, filename: "async.bin")
      assert_kind_of PendingResult, r
      assert_equal "pending-1", r.id
      assert_equal "/v2.2/files/pending-1", r.resource_location
    end

    def test_process_async_file_expects_202
      file = make_temp_file("async")
      stub_request(:post, "#{BASE}/files/async").to_return(
        status: 202,
        body: '{"id":"pending-1"}',
        headers: { "Location" => "/v2.2/files/pending-1" }
      )
      r = @client.process_async_file(file)
      assert_kind_of PendingResult, r
      assert_equal "pending-1", r.id
      assert_equal "/v2.2/files/pending-1", r.resource_location
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    def test_process_async_path_deprecated_emits_warning
      file = make_temp_file("async dep")
      stub_request(:post, "#{BASE}/files/async").to_return(
        status: 202,
        body: '{"id":"x"}',
        headers: { "Location" => "/v2.2/files/x" }
      )
      _out, err = capture_io { @client.process_async(file) }
      assert_match(/deprecated/, err)
      assert_match(/process_async_file/, err)
      assert_match(/future major version/, err)
    ensure
      File.unlink(file) if file && File.exist?(file)
    end

    # -- fetch --------------------------------------------------------------

    def test_fetch_posts_form_encoded
      stub = stub_request(:post, "#{BASE}/files/fetch")
             .with(headers: { "Content-Type" => "application/x-www-form-urlencoded" }) do |req|
               req.body.include?("location=https%3A%2F%2Fexample.com%2Fx.bin") &&
                 req.body.include?("callback=https%3A%2F%2Fcb.example%2Fy") &&
                 req.body.include?("metadata%5Bk%5D=v")
             end
             .to_return(status: 202, body: '{"id":"f1"}')
      r = @client.fetch("https://example.com/x.bin", metadata: { "k" => "v" }, callback: "https://cb.example/y")
      assert_kind_of PendingResult, r
      assert_equal "f1", r.id
      assert_requested(stub)
    end

    def test_fetch_rejects_empty_url
      assert_raises(ArgumentError) { @client.fetch("") }
    end

    # -- retrieve -----------------------------------------------------------

    def test_retrieve_url_encodes_id
      odd_id = "abc/def"
      stub = stub_request(:get, "#{BASE}/files/abc%2Fdef").to_return(status: 200,
                                                                     body: '{"id":"abc/def","findings":[]}')
      @client.retrieve(odd_id)
      assert_requested(stub)
    end

    def test_retrieve_rejects_empty_id
      assert_raises(ArgumentError) { @client.retrieve("") }
    end

    def test_retrieve_raises_on_404
      stub_request(:get, "#{BASE}/files/missing").to_return(status: 404, body: '{"error":"not found"}')
      err = assert_raises(Error) { @client.retrieve("missing") }
      assert_equal 404, err.status_code
      refute_kind_of AuthError, err
      refute_kind_of RateLimitError, err
    end

    # -- auth tokens --------------------------------------------------------

    def test_create_auth_token_posts_timeout
      body = '{"id":"tok","creation_date":"2026-04-29T00:00:00Z","expiration_date":"2026-04-29T00:05:00Z"}'
      stub = stub_request(:post, "#{BASE}/auth/tokens")
             .with(
               headers: { "Content-Type" => "application/x-www-form-urlencoded" },
               body: "timeout=300"
             )
             .to_return(status: 201, body: body)
      tok = @client.create_auth_token(300)
      assert_kind_of AuthToken, tok
      assert_equal "tok", tok.id
      assert_equal "2026-04-29T00:00:00Z", tok.creation_date
      assert_equal "2026-04-29T00:05:00Z", tok.expiration_date
      assert_requested(stub)
    end

    def test_create_auth_token_rejects_zero_or_negative
      assert_raises(ArgumentError) { @client.create_auth_token(0) }
      assert_raises(ArgumentError) { @client.create_auth_token(-1) }
    end

    def test_retrieve_auth_token_get
      stub_request(:get, "#{BASE}/auth/tokens/tok").to_return(status: 200, body: '{"id":"tok"}')
      assert_equal "tok", @client.retrieve_auth_token("tok").id
    end

    def test_delete_auth_token_returns_true_on_204
      stub_request(:delete, "#{BASE}/auth/tokens/tok").to_return(status: 204)
      assert_equal true, @client.delete_auth_token("tok")
    end

    # -- delete / delete_trace ---------------------------------------------

    def test_delete_sends_delete_to_files_path_and_returns_true
      stub = stub_request(:delete, "#{BASE}/files/abc").to_return(status: 204)
      assert_equal true, @client.delete("abc")
      assert_requested(stub)
    end

    def test_delete_trace_sends_delete_to_trace_path_and_returns_true
      stub = stub_request(:delete, "#{BASE}/files/abc/trace").to_return(status: 204)
      assert_equal true, @client.delete_trace("abc")
      assert_requested(stub)
    end

    def test_delete_404_raises_scanii_error
      stub_request(:delete, "#{BASE}/files/missing")
        .to_return(status: 404, body: { error: "not found" }.to_json)
      err = assert_raises(Error) { @client.delete("missing") }
      assert_equal 404, err.status_code
    end

    def test_delete_trace_404_raises_scanii_error
      stub_request(:delete, "#{BASE}/files/missing/trace")
        .to_return(status: 404, body: { error: "no trace" }.to_json)
      err = assert_raises(Error) { @client.delete_trace("missing") }
      assert_equal 404, err.status_code
    end

    # Per the spec a temporary auth token is not privileged to delete.
    def test_delete_403_raises_auth_error
      stub_request(:delete, "#{BASE}/files/abc")
        .to_return(status: 403, body: { error: "forbidden" }.to_json)
      assert_raises(AuthError) { @client.delete("abc") }
    end

    def test_delete_trace_403_raises_auth_error
      stub_request(:delete, "#{BASE}/files/abc/trace")
        .to_return(status: 403, body: { error: "forbidden" }.to_json)
      assert_raises(AuthError) { @client.delete_trace("abc") }
    end

    def test_delete_empty_id_raises_argument_error
      assert_raises(ArgumentError) { @client.delete("") }
    end

    def test_delete_trace_empty_id_raises_argument_error
      assert_raises(ArgumentError) { @client.delete_trace("") }
    end

    # -- transport errors --------------------------------------------------

    def test_connection_refused_raises_scanii_error
      stub_request(:get, "#{BASE}/ping").to_raise(Errno::ECONNREFUSED)
      err = assert_raises(Error) { @client.ping }
      assert_match(/transport error/, err.message)
    end

    # -- VERSION constant matches gemspec --------------------------------

    def test_version_constant_present
      assert_match(/\A\d+\.\d+\.\d+/, Scanii::VERSION)
    end

    private

    def make_temp_file(contents)
      path = File.join(Dir.tmpdir, "scanii-ruby-unit-#{Process.pid}-#{rand(1 << 32)}.bin")
      File.binwrite(path, contents)
      path
    end
  end

  class MultipartUnitTest < Minitest::Test
    def setup
      WebMock.enable! if defined?(WebMock)
    end

    def test_stream_encode_emits_well_formed_body
      io = StringIO.new("hello world")
      chained, ct, length = Multipart.stream_encode({ "metadata[source]" => "unit" }, io, "test.txt")
      body = chained.read
      assert_match(%r{\Amultipart/form-data; boundary=----scanii-ruby-boundary-}, ct)
      assert_includes body, %(name="metadata[source]")
      assert_includes body, %(name="file"; filename=)
      assert_includes body, "hello world"
      assert body.end_with?("--\r\n"), "expected closing boundary terminator"
      assert_equal length, body.bytesize
    end

    def test_stream_encode_handles_binary_content
      bytes = (0..255).to_a.pack("C*")
      io = StringIO.new(bytes)
      chained, = Multipart.stream_encode({}, io, "binary.bin")
      body = chained.read
      assert_equal Encoding::BINARY, body.encoding
      assert_includes body, bytes
    end

    def test_stream_encode_content_length_matches_actual_body
      io = StringIO.new("measure me")
      _, _, length = Multipart.stream_encode({}, io, "measure.txt")
      # Re-create to read from the start
      io2 = StringIO.new("measure me")
      chained2, = Multipart.stream_encode({}, io2, "measure.txt")
      assert_equal length, chained2.read.bytesize
    end

    def test_stream_encode_file_io
      path = File.join(Dir.tmpdir, "scanii-ruby-mp-#{Process.pid}-#{rand(1 << 32)}.txt")
      File.binwrite(path, "hello world")
      File.open(path, "rb") do |f|
        chained, ct, length = Multipart.stream_encode({ "metadata[source]" => "unit" }, f, "test.txt")
        body = chained.read
        assert_match(%r{\Amultipart/form-data; boundary=----scanii-ruby-boundary-}, ct)
        assert_includes body, "hello world"
        assert_equal length, body.bytesize
      end
    ensure
      File.unlink(path) if path && File.exist?(path)
    end

    def test_guess_content_type_known_extensions
      assert_equal "text/plain", Multipart.guess_content_type("a.txt")
      assert_equal "application/pdf", Multipart.guess_content_type("a.PDF")
      assert_equal "application/octet-stream", Multipart.guess_content_type("nope")
    end

    def test_make_boundary_unique
      a = Multipart.make_boundary
      b = Multipart.make_boundary
      refute_equal a, b
    end
  end
end
