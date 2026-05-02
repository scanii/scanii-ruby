require "json"

module Scanii
  # Result of Client#retrieve_trace — ordered processing events for a scan.
  #
  # This is a v2.2 preview surface; the API shape may shift before it is
  # marked stable.
  #
  # @see https://scanii.github.io/openapi/v22/
  class TraceResult
    attr_reader :id, :events, :request_id, :host_id, :raw_response

    def initialize(id:, events:, request_id:, host_id:, raw_response:)
      @id           = id
      @events       = events
      @request_id   = request_id
      @host_id      = host_id
      @raw_response = raw_response
    end

    def self.from_response(body, headers)
      json = body.nil? || body.empty? ? {} : JSON.parse(body)

      new(
        id: (json["id"] || "").to_s,
        events: Array(json["events"]).map { |e| TraceEvent.from_hash(e) },
        request_id: headers["x-scanii-request-id"],
        host_id: headers["x-scanii-host-id"],
        raw_response: body
      )
    end
  end
end
