module Scanii
  # Base class for all errors raised by Scanii::Client. Carries the API-supplied
  # message plus optional X-Scanii-Request-Id and X-Scanii-Host-Id headers for
  # support handoffs.
  #
  # Per SDK Principle 3 (integration-only) the SDK does not retry on the caller's
  # behalf -- backoff is the caller's responsibility.
  #
  # @see https://scanii.github.io/openapi/v22/
  class Error < StandardError
    attr_reader :status_code, :request_id, :host_id, :body

    def initialize(message, status_code: nil, request_id: nil, host_id: nil, body: nil)
      super(message)
      @status_code = status_code
      @request_id  = request_id
      @host_id     = host_id
      @body        = body
    end
  end

  # Raised on HTTP 401 / 403 -- the credentials were rejected by the API.
  class AuthError < Error
  end

  # Raised on HTTP 429. retry_after carries the value of the Retry-After
  # response header in seconds when the server provided one.
  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message, retry_after: nil, **)
      super(message, **)
      @retry_after = retry_after
    end
  end
end
