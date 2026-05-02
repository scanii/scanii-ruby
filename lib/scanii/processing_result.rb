require "json"

module Scanii
  # Result of a synchronous file scan returned by Client#process and
  # Client#retrieve.
  #
  # findings is always an Array. Empty array means the content is clean.
  #
  # @see https://scanii.github.io/openapi/v22/
  class ProcessingResult
    attr_reader :id, :findings, :checksum, :content_length, :content_type,
                :metadata, :creation_date,
                :request_id, :host_id, :resource_location, :raw_response

    def initialize(id:, findings:, checksum:, content_length:, content_type:,
                   metadata:, creation_date:, error:,
                   request_id:, host_id:, resource_location:, raw_response:)
      @id                = id
      @findings          = findings
      @checksum          = checksum
      @content_length    = content_length
      @content_type      = content_type
      @metadata          = metadata
      @creation_date     = creation_date
      @_error            = error
      @request_id        = request_id
      @host_id           = host_id
      @resource_location = resource_location
      @raw_response      = raw_response
    end

    # @deprecated The server never populates this field on successful responses;
    #   errors arrive as non-2xx HTTP responses that raise Scanii::Error
    #   subclasses. Will be removed in a future major version.
    def error
      warn "[DEPRECATION] `Scanii::ProcessingResult#error` is deprecated; " \
           "rescue Scanii::Error (and its subclasses) to handle server-side errors. " \
           "Will be removed in a future major version."
      @_error
    end

    def self.from_response(body, headers)
      json = body.nil? || body.empty? ? {} : JSON.parse(body)

      new(
        id: (json["id"] || "").to_s,
        findings: Array(json["findings"]).map(&:to_s),
        checksum: json["checksum"]&.to_s,
        content_length: json["content_length"]&.to_i,
        content_type: json["content_type"]&.to_s,
        metadata: (json["metadata"] || {}).transform_values(&:to_s),
        creation_date: json["creation_date"]&.to_s,
        error: json["error"]&.to_s,
        request_id: headers["x-scanii-request-id"],
        host_id: headers["x-scanii-host-id"],
        resource_location: headers["location"],
        raw_response: body
      )
    end
  end
end
