require "securerandom"
require "stringio"

module Scanii
  # Hand-rolled multipart/form-data encoder (RFC 7578).
  #
  # Ruby's stdlib Net::HTTP does not bundle a multipart encoder; this is the
  # smallest viable implementation that covers the Scanii POST /files payload.
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

    # Encode a multipart body as a streaming ChainedIO.
    #
    # Builds the RFC 7578 prologue and epilogue as binary Strings, chains them
    # around the caller's IO, and returns the triple required for
    # Net::HTTP body_stream= uploads. The caller's IO is never read here --
    # only when Net::HTTP reads from the returned ChainedIO.
    #
    # @param fields [Hash{String=>String}] text form fields (e.g. metadata[k]=v, callback)
    # @param io [#read, #size] IO-like object (anything responding to read(n))
    # @param filename [String] filename for the file part
    # @param content_type [String, nil] content-type of the file part; falls back to extension lookup
    # @param file_field [String] name of the file form field; default "file"
    # @return [Array(ChainedIO, String, Integer)] [body_stream, content_type_header, content_length]
    def stream_encode(fields, io, filename, content_type = nil, file_field: "file")
      boundary = make_boundary
      ct = content_type || guess_content_type(filename)

      prologue = String.new(encoding: Encoding::BINARY)
      fields.each do |name, value|
        write_text_part(prologue, boundary, name.to_s, value.to_s)
      end
      prologue << "--#{boundary}\r\n".b
      prologue << "Content-Disposition: form-data; name=\"#{file_field}\"; filename=\"#{filename}\"\r\n".b
      prologue << "Content-Type: #{ct}\r\n\r\n".b

      epilogue = "\r\n--#{boundary}--\r\n".b

      io_size = io_remaining_bytes(io)
      total_length = prologue.bytesize + io_size + epilogue.bytesize

      [ChainedIO.new(prologue, io, epilogue), make_content_type(boundary), total_length]
    end

    # Best-effort content-type lookup by filename extension. Falls back to
    # application/octet-stream. The Scanii API does not require an accurate
    # content-type on the multipart part -- the server inspects the bytes -- so
    # a short table is sufficient.
    def guess_content_type(filename)
      ext = File.extname(filename.to_s).delete_prefix(".").downcase
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

    # Return the number of bytes remaining to be read from io.
    # Requires io to respond to size (File and StringIO both do).
    def io_remaining_bytes(io)
      if io.respond_to?(:pos) && io.respond_to?(:size)
        io.size - io.pos
      elsif io.respond_to?(:size)
        io.size
      else
        raise ArgumentError, "io must respond to size (File and StringIO do; got #{io.class})"
      end
    end
    private_class_method :io_remaining_bytes

    # Reads prologue_str, then io, then epilogue_str in sequence.
    # Used as Net::HTTP body_stream for streaming multipart uploads.
    class ChainedIO
      def initialize(prologue, io, epilogue)
        @parts = [StringIO.new(prologue), io, StringIO.new(epilogue)]
        @idx   = 0
      end

      def read(length = nil, buf = nil)
        result = length.nil? ? read_all : read_n(length)
        return nil if result.nil?

        buf ? buf.replace(result) : result
      end

      private

      def read_all
        result = String.new(encoding: Encoding::BINARY)
        @parts[@idx..].each do |part|
          chunk = part.read
          result << chunk.b if chunk
        end
        @idx = @parts.size
        result
      end

      def read_n(length)
        result = String.new(encoding: Encoding::BINARY)
        while result.bytesize < length && @idx < @parts.size
          chunk = @parts[@idx].read(length - result.bytesize)
          if chunk.nil? || chunk.empty?
            @idx += 1
          else
            result << chunk.b
          end
        end
        result.empty? ? nil : result
      end
    end
    private_constant :ChainedIO
  end
end
