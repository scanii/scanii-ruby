require "json"
require "net/http"
require "uri"

module Scanii
  # Synchronous client for the Scanii REST API v2.2.
  #
  # Construct with either +key:+ + +secret:+ (HTTP Basic Auth) or +token:+
  # (auth-token authentication). Mixing the two raises ArgumentError.
  #
  # Per SDK Principle 3 the client is integration-only: it does not retry,
  # batch, or paginate. Each public method maps to exactly one HTTP request.
  #
  # @see https://scanii.github.io/openapi/v22/
  #
  # @example Scan a file from disk
  #   client = Scanii::Client.new(key: "your-key", secret: "your-secret")
  #   result = client.process_file("./file.pdf")
  #   puts result.findings  # [] when clean
  #
  # @example Scan content already in memory
  #   result = client.process(StringIO.new(bytes), filename: "upload.bin")
  class Client
    DEFAULT_ENDPOINT = "https://api.scanii.com".freeze
    DEFAULT_TIMEOUT  = 60
    API_VERSION_PATH = "/v2.2".freeze
    USER_AGENT       = "scanii-ruby/#{Scanii::VERSION}".freeze

    attr_reader :endpoint, :timeout, :user_agent

    # @param key [String, nil] API key (mutually exclusive with token)
    # @param secret [String, nil] API secret (required when key is set)
    # @param token [String, nil] auth-token id (mutually exclusive with key/secret)
    # @param endpoint [Scanii::Target, String] base URL or {Scanii::Target} constant;
    #   defaults to https://api.scanii.com (deprecated)
    #   @deprecated The default endpoint (https://api.scanii.com) uses latency-based routing
    #     and does not guarantee which region processes your data. Pass an explicit regional
    #     endpoint for data residency compliance: {Scanii::Target::US1}, {Scanii::Target::EU1},
    #     {Scanii::Target::EU2}, {Scanii::Target::AP1}, {Scanii::Target::AP2},
    #     {Scanii::Target::CA1}. A bare URL String is also accepted (e.g. for scanii-cli).
    #     Will be removed in a future major version.
    # @param timeout [Integer] open + read timeout in seconds; default 60
    # @param user_agent [String, nil] optional fragment prepended to the SDK's default User-Agent
    def initialize(key: nil, secret: nil, token: nil, endpoint: DEFAULT_ENDPOINT,
                   timeout: DEFAULT_TIMEOUT, user_agent: nil)
      if endpoint == DEFAULT_ENDPOINT
        warn "[scanii] DEPRECATION: No explicit endpoint set; defaulting to " \
             "#{DEFAULT_ENDPOINT} (AUTO routing). This does not guarantee regional data " \
             "placement. Pass an explicit regional endpoint (e.g. Scanii::Target::US1) " \
             "for data residency compliance. The AUTO default will be removed in a " \
             "future major version."
      end
      @auth_header = build_auth_header(key, secret, token)
      @endpoint    = endpoint.to_s.sub(%r{/+\z}, "")
      raise ArgumentError, "endpoint must not be empty" if @endpoint.empty?

      @base_uri = URI.parse("#{@endpoint}#{API_VERSION_PATH}")
      raise ArgumentError, "endpoint must be http(s)" unless %w[http https].include?(@base_uri.scheme)

      @timeout    = Integer(timeout)
      @user_agent = user_agent && !user_agent.empty? ? "#{user_agent} #{USER_AGENT}" : USER_AGENT
    end

    # Submit an IO-like object for synchronous scanning.
    #
    # +io+ is duck-typed: anything responding to +read(n)+ returning a String.
    # Both +File+ (opened with +File.open(path, "rb")+) and +StringIO+ work.
    # The body is streamed to the socket; file content is never fully buffered.
    #
    # Passing a String path is deprecated — use {#process_file} instead.
    #
    # @overload process(io, filename:, content_type: nil, metadata: nil, callback: nil)
    #   @param io [#read] IO-like object
    #   @param filename [String] filename sent in the multipart part
    #   @param content_type [String, nil] content-type of the file part; guessed from filename when nil
    #   @param metadata [Hash{String=>String}, nil] arbitrary key/value pairs attached to the result
    #   @param callback [String, nil] URL to POST the result to on completion
    #
    # @see https://scanii.github.io/openapi/v22/  POST /files
    # @return [Scanii::ProcessingResult]
    def process(first_arg, filename: nil, content_type: nil, metadata: nil, callback: nil)
      if first_arg.is_a?(String)
        # @deprecated Use {#process_file} instead. Will be removed in a future major version.
        warn "[DEPRECATION] `Scanii::Client#process(path)` is deprecated; " \
             "use `process_file(path)` instead. Will be removed in a future major version."
        return process_file(first_arg, metadata: metadata, callback: callback)
      end

      raise ArgumentError, "io must respond to read" unless first_arg.respond_to?(:read)
      raise ArgumentError, "filename: is required" if filename.nil? || filename.to_s.empty?

      fields = build_text_fields(metadata, callback)
      stream, ct, length = Multipart.stream_encode(fields, first_arg, filename.to_s, content_type)
      status, resp_body, headers = post("/files", body_stream: stream, content_type: ct,
                                                  content_length: length)
      raise_for_status(status, resp_body, headers) unless status == 201
      ProcessingResult.from_response(resp_body, headers)
    end

    # Submit a file path for synchronous scanning.
    #
    # Opens the file in binary mode, streams it to Scanii, and closes it.
    # Delegates to {#process} with +filename+ set to the basename.
    #
    # @param file_path [String] path to the file to upload
    # @param metadata [Hash{String=>String}, nil]
    # @param callback [String, nil]
    # @see https://scanii.github.io/openapi/v22/  POST /files
    # @return [Scanii::ProcessingResult]
    def process_file(file_path, metadata: nil, callback: nil)
      assert_readable(file_path)
      File.open(file_path.to_s, "rb") do |f|
        process(f, filename: File.basename(file_path.to_s), metadata: metadata, callback: callback)
      end
    end

    # Submit an IO-like object for server-side asynchronous scanning.
    #
    # Returns a pending id; the final result is delivered to +callback+ (when
    # supplied) or fetched via {#retrieve}.
    #
    # Passing a String path is deprecated — use {#process_async_file} instead.
    #
    # @overload process_async(io, filename:, content_type: nil, metadata: nil, callback: nil)
    #   @param io [#read] IO-like object
    #   @param filename [String] filename sent in the multipart part
    #   @param content_type [String, nil]
    #   @param metadata [Hash{String=>String}, nil]
    #   @param callback [String, nil]
    #
    # @see https://scanii.github.io/openapi/v22/  POST /files/async
    # @return [Scanii::PendingResult]
    def process_async(first_arg, filename: nil, content_type: nil, metadata: nil, callback: nil)
      if first_arg.is_a?(String)
        # @deprecated Use {#process_async_file} instead. Will be removed in a future major version.
        warn "[DEPRECATION] `Scanii::Client#process_async(path)` is deprecated; " \
             "use `process_async_file(path)` instead. Will be removed in a future major version."
        return process_async_file(first_arg, metadata: metadata, callback: callback)
      end

      raise ArgumentError, "io must respond to read" unless first_arg.respond_to?(:read)
      raise ArgumentError, "filename: is required" if filename.nil? || filename.to_s.empty?

      fields = build_text_fields(metadata, callback)
      stream, ct, length = Multipart.stream_encode(fields, first_arg, filename.to_s, content_type)
      status, resp_body, headers = post("/files/async", body_stream: stream, content_type: ct,
                                                        content_length: length)
      raise_for_status(status, resp_body, headers) unless status == 202
      PendingResult.from_response(resp_body, headers)
    end

    # Submit a file path for server-side asynchronous scanning.
    #
    # Opens the file in binary mode and delegates to {#process_async}.
    #
    # @param file_path [String] path to the file to upload
    # @param metadata [Hash{String=>String}, nil]
    # @param callback [String, nil]
    # @see https://scanii.github.io/openapi/v22/  POST /files/async
    # @return [Scanii::PendingResult]
    def process_async_file(file_path, metadata: nil, callback: nil)
      assert_readable(file_path)
      File.open(file_path.to_s, "rb") do |f|
        process_async(f, filename: File.basename(file_path.to_s), metadata: metadata,
                         callback: callback)
      end
    end

    # Ask Scanii to download a remote URL and scan it asynchronously.
    #
    # @see https://scanii.github.io/openapi/v22/  POST /files/fetch
    # @return [Scanii::PendingResult]
    def fetch(url, metadata: nil, callback: nil)
      raise ArgumentError, "url must not be empty" if url.nil? || url.empty?

      form = { "location" => url }
      form["callback"] = callback if callback && !callback.empty?
      (metadata || {}).each { |k, v| form["metadata[#{k}]"] = v.to_s }

      status, resp_body, headers = post(
        "/files/fetch",
        body: URI.encode_www_form(form),
        content_type: "application/x-www-form-urlencoded"
      )
      raise_for_status(status, resp_body, headers) unless status == 202
      PendingResult.from_response(resp_body, headers)
    end

    # Retrieve a previously submitted scan result by id.
    #
    # @see https://scanii.github.io/openapi/v22/  GET /files/{id}
    # @return [Scanii::ProcessingResult]
    def retrieve(id)
      raise ArgumentError, "id must not be empty" if id.nil? || id.empty?

      status, resp_body, headers = request("GET", "/files/#{url_encode(id)}")
      raise_for_status(status, resp_body, headers) unless status == 200
      ProcessingResult.from_response(resp_body, headers)
    end

    # Retrieve the processing event trace for a previously submitted scan.
    #
    # Returns nil when no trace exists for the given id (HTTP 404).
    #
    # This is a v2.2 preview surface; the API shape may shift before it is
    # marked stable.
    #
    # @param id [String] processing id returned by process or process_file
    # @see https://scanii.github.io/openapi/v22/  GET /files/{id}/trace
    # @return [Scanii::TraceResult, nil]
    def retrieve_trace(id)
      raise ArgumentError, "id must not be empty" if id.nil? || id.empty?

      status, resp_body, headers = request("GET", "/files/#{url_encode(id)}/trace")
      return nil if status == 404

      raise_for_status(status, resp_body, headers) unless status == 200
      TraceResult.from_response(resp_body, headers)
    end

    # Submit a remote URL for synchronous scanning.
    #
    # Sends the URL as a +location+ field in a multipart/form-data POST to
    # +/files+. The Scanii server fetches and scans the URL synchronously and
    # returns a ProcessingResult. This is distinct from {#fetch}, which submits
    # to +/files/fetch+ for asynchronous server-side fetching.
    #
    # +location+ must be a String URL. This matches the existing {#fetch}
    # String-URL convention and the Java reference (processFromUrl(String)).
    #
    # This is a v2.2 preview surface; the API shape may shift before it is
    # marked stable.
    #
    # @param location [String] URL of the content to scan
    # @param callback [String, nil] URL to POST the result to on completion
    # @param metadata [Hash{String=>String}, nil] arbitrary key/value pairs attached to the result
    # @see https://scanii.github.io/openapi/v22/  POST /files
    # @return [Scanii::ProcessingResult]
    def process_from_url(location, callback: nil, metadata: nil)
      raise ArgumentError, "location must not be empty" if location.nil? || location.to_s.empty?

      fields = build_text_fields(metadata, callback)
      fields["location"] = location.to_s

      boundary = Multipart.make_boundary
      body = String.new(encoding: Encoding::BINARY)
      fields.each do |name, value|
        body << "--#{boundary}\r\n".b
        body << "Content-Disposition: form-data; name=\"#{name}\"\r\n".b
        body << "Content-Type: text/plain; charset=UTF-8\r\n\r\n".b
        body << value.to_s.b
        body << "\r\n".b
      end
      body << "--#{boundary}--\r\n".b

      status, resp_body, headers = post(
        "/files",
        body: body,
        content_type: Multipart.make_content_type(boundary)
      )
      raise_for_status(status, resp_body, headers) unless status == 201
      ProcessingResult.from_response(resp_body, headers)
    end

    # Verify that the configured credentials reach the API.
    #
    # @see https://scanii.github.io/openapi/v22/  GET /ping
    # @return [Boolean] true when the API responds 200
    def ping
      status, resp_body, headers = request("GET", "/ping")
      return true if status == 200

      raise_for_status(status, resp_body, headers)
    end

    # Mint a short-lived auth token. timeout_seconds must be positive.
    #
    # @see https://scanii.github.io/openapi/v22/  POST /auth/tokens
    # @return [Scanii::AuthToken]
    def create_auth_token(timeout_seconds)
      ts = Integer(timeout_seconds)
      raise ArgumentError, "timeout_seconds must be positive" if ts <= 0

      status, resp_body, headers = post(
        "/auth/tokens",
        body: URI.encode_www_form("timeout" => ts),
        content_type: "application/x-www-form-urlencoded"
      )
      raise_for_status(status, resp_body, headers) unless [200, 201].include?(status)
      AuthToken.from_response(resp_body, headers)
    end

    # Inspect a previously created auth token.
    #
    # @see https://scanii.github.io/openapi/v22/  GET /auth/tokens/{id}
    # @return [Scanii::AuthToken]
    def retrieve_auth_token(id)
      raise ArgumentError, "id must not be empty" if id.nil? || id.empty?

      status, resp_body, headers = request("GET", "/auth/tokens/#{url_encode(id)}")
      raise_for_status(status, resp_body, headers) unless status == 200
      AuthToken.from_response(resp_body, headers)
    end

    # Revoke an auth token.
    #
    # @see https://scanii.github.io/openapi/v22/  DELETE /auth/tokens/{id}
    # @return [Boolean] true on 204
    def delete_auth_token(id)
      raise ArgumentError, "id must not be empty" if id.nil? || id.empty?

      status, resp_body, headers = request("DELETE", "/auth/tokens/#{url_encode(id)}")
      raise_for_status(status, resp_body, headers) unless status == 204
      true
    end

    private

    def build_auth_header(key, secret, token)
      if token && !token.empty?
        raise ArgumentError, "supply either token: or key:+secret:, not both" if key || secret

        "Basic #{base64_encode("#{token}:")}"
      else
        raise ArgumentError, "key must be set (or use token: for auth-token mode)" if key.nil? || key.empty?
        raise ArgumentError, "key must not contain a colon" if key.include?(":")
        raise ArgumentError, "secret must be set when using key auth" if secret.nil? || secret.empty?

        "Basic #{base64_encode("#{key}:#{secret}")}"
      end
    end

    # Stdlib-only base64. Array#pack("m0") emits RFC 4648 base64 with no
    # newlines -- identical output to Base64.strict_encode64 -- without
    # requiring the unbundled `base64` gem on Ruby 3.4+.
    def base64_encode(value)
      [value].pack("m0")
    end

    def assert_readable(path)
      raise ArgumentError, "file at #{path} is not readable" unless File.file?(path) && File.readable?(path)
    end

    def build_text_fields(metadata, callback)
      fields = {}
      (metadata || {}).each { |k, v| fields["metadata[#{k}]"] = v.to_s }
      fields["callback"] = callback if callback && !callback.empty?
      fields
    end

    def post(path, body: nil, content_type: nil, body_stream: nil, content_length: nil)
      request("POST", path, body: body, content_type: content_type,
                            body_stream: body_stream, content_length: content_length)
    end

    def request(method, path, body: nil, content_type: nil, body_stream: nil, content_length: nil)
      uri = URI.parse("#{@base_uri}#{path}")

      req = build_request(method, uri, body: body, content_type: content_type,
                                       body_stream: body_stream, content_length: content_length)

      Net::HTTP.start(uri.hostname, uri.port,
                      use_ssl: uri.scheme == "https",
                      open_timeout: @timeout,
                      read_timeout: @timeout) do |http|
        response = http.request(req)
        headers = capture_headers(response)
        [response.code.to_i, response.body.to_s, headers]
      end
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise Scanii::Error, "transport error: #{e.class}: #{e.message}"
    end

    def build_request(method, uri, body: nil, content_type: nil, body_stream: nil, content_length: nil)
      klass = case method
              when "GET"    then Net::HTTP::Get
              when "POST"   then Net::HTTP::Post
              when "DELETE" then Net::HTTP::Delete
              else raise ArgumentError, "unsupported method: #{method}"
              end

      req = klass.new(uri.request_uri)
      req["Authorization"] = @auth_header
      req["User-Agent"]    = @user_agent
      req["Accept"]        = "application/json"
      req["Content-Type"]  = content_type if content_type

      if body_stream
        req.body_stream = body_stream
        req["Content-Length"] = content_length.to_s
      elsif body
        req.body = body
      end

      req
    end

    def capture_headers(response)
      headers = {}
      response.each_header { |name, value| headers[name.downcase] = value }
      headers
    end

    def raise_for_status(status, body, headers)
      request_id = headers["x-scanii-request-id"]
      host_id    = headers["x-scanii-host-id"]
      message    = extract_error_message(body) || "HTTP #{status}"

      case status
      when 401, 403
        raise Scanii::AuthError.new(message, status_code: status, request_id: request_id,
                                             host_id: host_id, body: body)
      when 429
        retry_after = headers["retry-after"]&.to_i
        raise Scanii::RateLimitError.new(message, status_code: status, request_id: request_id,
                                                  host_id: host_id, body: body, retry_after: retry_after)
      else
        raise Scanii::Error.new(message, status_code: status, request_id: request_id,
                                         host_id: host_id, body: body)
      end
    end

    def extract_error_message(body)
      return nil if body.nil? || body.empty?

      decoded = JSON.parse(body)
      return decoded["error"].to_s if decoded.is_a?(Hash) && decoded["error"].is_a?(String)

      body
    rescue JSON::ParserError
      body
    end

    def url_encode(value)
      URI.encode_www_form_component(value)
    end
  end
end
