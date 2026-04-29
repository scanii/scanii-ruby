require "securerandom"

module Scanii
  # Hand-rolled multipart/form-data encoder (RFC 7578).
  #
  # Ruby's stdlib Net::HTTP does not bundle a multipart encoder; this is the
  # smallest viable implementation that covers the Scanii POST /files payload.
  #
  # Body is assembled as a single binary-encoded String -- file contents are
  # read into memory rather than streamed. This matches the PHP SDK's approach;
  # callers scanning very large files should be aware.
  module Multipart
    module_function

    # Generate a unique multipart boundary.
    def make_boundary
      "----scanii-ruby-boundary-#{SecureRandom.hex(16)}"
    end

    # Build the Content-Type header value for a request using boundary.
    def make_content_type(boundary)
      "multipart/form-data; boundary=#{boundary}"
    end

    # Encode a multipart body containing the bytes at file_path plus the given
    # text fields.
    #
    # @param fields [Hash{String=>String}] text form fields (e.g. metadata[k] => v, callback => url)
    # @param file_path [String] path to the file to upload
    # @param file_field [String] name of the file form field; default "file"
    # @return [Array(String, String)] tuple of [body, content_type]
    def encode(fields, file_path, file_field: "file")
      boundary = make_boundary

      filename = File.basename(file_path)
      content_type = guess_content_type(file_path)
      file_bytes = File.binread(file_path)

      body = String.new(encoding: Encoding::BINARY)

      fields.each do |name, value|
        write_text_part(body, boundary, name.to_s, value.to_s)
      end

      body << "--#{boundary}\r\n".b
      body << "Content-Disposition: form-data; name=\"#{file_field}\"; filename=\"#{filename}\"\r\n".b
      body << "Content-Type: #{content_type}\r\n\r\n".b
      body << file_bytes.b
      body << "\r\n".b
      body << "--#{boundary}--\r\n".b

      [body, make_content_type(boundary)]
    end

    # Best-effort content-type lookup by extension. Falls back to
    # application/octet-stream. The Scanii API does not require an accurate
    # content-type on the multipart part -- the server inspects the bytes -- so
    # a short table is sufficient.
    def guess_content_type(path)
      ext = File.extname(path).delete_prefix(".").downcase
      MIME_TYPES.fetch(ext, "application/octet-stream")
    end

    MIME_TYPES = {
      "txt" => "text/plain",
      "html" => "text/html",
      "htm" => "text/html",
      "css" => "text/css",
      "csv" => "text/csv",
      "json" => "application/json",
      "xml" => "application/xml",
      "pdf" => "application/pdf",
      "zip" => "application/zip",
      "gz" => "application/gzip",
      "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg",
      "png" => "image/png",
      "gif" => "image/gif",
      "webp" => "image/webp",
      "svg" => "image/svg+xml",
      "mp3" => "audio/mpeg",
      "mp4" => "video/mp4",
      "mov" => "video/quicktime",
      "doc" => "application/msword",
      "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "xls" => "application/vnd.ms-excel",
      "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }.freeze
    private_constant :MIME_TYPES

    def write_text_part(body, boundary, name, value)
      body << "--#{boundary}\r\n".b
      body << "Content-Disposition: form-data; name=\"#{name}\"\r\n".b
      body << "Content-Type: text/plain; charset=UTF-8\r\n\r\n".b
      body << value.b
      body << "\r\n".b
    end
    private_class_method :write_text_part
  end
end
