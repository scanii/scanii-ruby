require "json"

module Scanii
  # Result of an asynchronous scan submission returned by Client#process_async
  # and Client#fetch.
  #
  # The actual scan result is fetched later via Client#retrieve, or delivered
  # to the supplied callback URL.
  #
  # @see https://scanii.github.io/openapi/v22/
  class PendingResult
    attr_reader :id, :request_id, :host_id, :resource_location, :raw_response

    def initialize(id:, request_id:, host_id:, resource_location:, raw_response:)
      @id                = id
      @request_id        = request_id
      @host_id           = host_id
      @resource_location = resource_location
      @raw_response      = raw_response
    end

    def self.from_response(body, headers)
      json = body.nil? || body.empty? ? {} : JSON.parse(body)

      new(
        id: (json["id"] || "").to_s,
        request_id: headers["x-scanii-request-id"],
        host_id: headers["x-scanii-host-id"],
        resource_location: headers["location"],
        raw_response: body
      )
    end
  end
end
