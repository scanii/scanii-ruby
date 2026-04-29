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
  # @example
  #   client = Scanii::Client.new(key: "your-key", secret: "your-secret")
  #   result = client.process("./file.pdf")
  #   puts result.findings  # [] when clean
  class Client
    DEFAULT_ENDPOINT = "https://api.scanii.com".freeze
    DEFAULT_TIMEOUT  = 60
    API_VERSION_PATH = "/v2.2".freeze
    USER_AGENT       = "scanii-ruby/#{Scanii::VERSION}".freeze

    attr_reader :endpoint, :timeout, :user_agent

    # @param key [String, nil] API key (mutually exclusive with token)
    # @param secret [String, nil] API secret (required when key is set)
    # @param token [String, nil] auth-token id (mutually exclusive with key/secret)
    # @param endpoint [String] base URL; defaults to https://api.scanii.com
    # @param timeout [Integer] open + read timeout in seconds; default 60
    # @param user_agent [String, nil] optional fragment prepended to the SDK's default User-Agent
    def initialize(key: nil, secret: nil, token: nil, endpoint: DEFAULT_ENDPOINT,
                   timeout: DEFAULT_TIMEOUT, user_agent: nil)
      @auth_header = build_auth_header(key, secret, token)
      @endpoint    = endpoint.to_s.sub(%r{/+\z}, "")
      raise ArgumentError, "endpoint must not be empty" if @endpoint.empty?

      @base_uri = URI.parse("#{@endpoint}#{API_VERSION_PATH}")
      raise ArgumentError, "endpoint must be http(s)" unless %w[http https].include?(@base_uri.scheme)

      @timeout    = Integer(timeout)
      @user_agent = user_agent && !user_agent.empty? ? "#{user_agent} #{USER_AGENT}" : USER_AGENT
    end

    # Submit a file for synchronous scanning.
    #
    # @see https://scanii.github.io/openapi/v22/  POST /files
    # @return [Scanii::ProcessingResult]
    def process(file_path, metadata: nil, callback: nil)
      assert_readable(file_path)
      fields = build_text_fields(metadata, callback)
      body, content_type = Multipart.encode(fields, file_path)
      status, resp_body, headers = post("/files", body: body, content_type: content_type)
      raise_for_status(status, resp_body, headers) unless status == 201
      ProcessingResult.from_response(resp_body, headers)
    end

    # Submit a file for server-side asynchronous scanning. Returns a pending
    # id; the final result is delivered to +callback+ (when supplied) or
    # fetched via #retrieve.
    #
    # @see https://scanii.github.io/openapi/v22/  POST /files/async
    # @return [Scanii::PendingResult]
    def process_async(file_path, metadata: nil, callback: nil)
      assert_readable(file_path)
      fields = build_text_fields(metadata, callback)
      body, content_type = Multipart.encode(fields, file_path)
      status, resp_body, headers = post("/files/async", body: body, content_type: content_type)
      raise_for_status(status, resp_body, headers) unless status == 202
      PendingResult.from_response(resp_body, headers)
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

    def post(path, body:, content_type:)
      request("POST", path, body: body, content_type: content_type)
    end

    def request(method, path, body: nil, content_type: nil)
      uri = URI.parse("#{@base_uri}#{path}")

      req = build_request(method, uri, body, content_type)

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

    def build_request(method, uri, body, content_type)
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
      req.body = body if body
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
