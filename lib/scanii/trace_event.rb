module Scanii
  # A single processing event in a {Scanii::TraceResult}.
  #
  # @see https://scanii.github.io/openapi/v22/
  class TraceEvent
    attr_reader :timestamp, :message

    def initialize(timestamp:, message:)
      @timestamp = timestamp
      @message   = message
    end

    def self.from_hash(hash)
      new(
        timestamp: hash["timestamp"]&.to_s,
        message: hash["message"]&.to_s
      )
    end
  end
end
