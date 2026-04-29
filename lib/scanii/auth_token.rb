require "json"

module Scanii
  # Short-lived auth token returned by Client#create_auth_token and
  # Client#retrieve_auth_token.
  #
  # Pass id back as the token: keyword argument when constructing a Client to
  # authenticate using the token instead of API key + secret.
  #
  # @see https://scanii.github.io/openapi/v22/
  class AuthToken
    attr_reader :id, :creation_date, :expiration_date,
                :request_id, :host_id, :resource_location, :raw_response

    def initialize(id:, creation_date:, expiration_date:,
                   request_id:, host_id:, resource_location:, raw_response:)
      @id                = id
      @creation_date     = creation_date
      @expiration_date   = expiration_date
      @request_id        = request_id
      @host_id           = host_id
      @resource_location = resource_location
      @raw_response      = raw_response
    end

    def self.from_response(body, headers)
      json = body.nil? || body.empty? ? {} : JSON.parse(body)

      new(
        id: (json["id"] || "").to_s,
        creation_date: json["creation_date"]&.to_s,
        expiration_date: json["expiration_date"]&.to_s,
        request_id: headers["x-scanii-request-id"],
        host_id: headers["x-scanii-host-id"],
        resource_location: headers["location"],
        raw_response: body
      )
    end
  end
end
