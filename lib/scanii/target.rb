module Scanii
  # Scanii regional API endpoints.
  #
  # Pass one of the predefined regional constants (e.g. {US1}) to
  # {Scanii::Client#initialize} via the +endpoint:+ keyword. The constructor
  # also accepts an arbitrary URL String for testing against scanii-cli or
  # other local mocks:
  #
  #   Scanii::Client.new(key: "k", secret: "s", endpoint: Scanii::Target::US1)
  #   Scanii::Client.new(key: "k", secret: "s", endpoint: Scanii::Target.new("http://localhost:4000"))
  #
  # +Scanii::Target::AUTO+ (latency-based routing) is intentionally not provided —
  # customer data residency / chain-of-custody compliance requires an explicit
  # regional choice.
  #
  # @see https://scanii.github.io/openapi/v22/
  class Target
    attr_reader :url

    # @param url [String] base URL for the target endpoint
    def initialize(url)
      raise ArgumentError, "Target URL must be a non-empty String" if url.nil? || url.to_s.empty?

      @url = url.to_s
    end

    # Coerce to String (the base URL). Lets +Scanii::Target+ instances be used
    # interchangeably with String URLs in +endpoint:+.
    def to_s
      @url
    end

    def ==(other)
      other.is_a?(Target) && other.url == @url
    end

    alias eql? ==

    def hash
      @url.hash
    end

    US1 = new("https://api-us1.scanii.com").freeze
    EU1 = new("https://api-eu1.scanii.com").freeze
    EU2 = new("https://api-eu2.scanii.com").freeze
    AP1 = new("https://api-ap1.scanii.com").freeze
    AP2 = new("https://api-ap2.scanii.com").freeze
    CA1 = new("https://api-ca1.scanii.com").freeze
  end
end
