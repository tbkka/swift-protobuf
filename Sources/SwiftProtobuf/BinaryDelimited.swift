// Sources/SwiftProtobuf/BinaryDelimited.swift - Delimited support
//
// Copyright (c) 2014 - 2017 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// Helpers to read/write message with a length prefix.
///
// -----------------------------------------------------------------------------

#if !os(WASI)
import Foundation
#endif

extension SwiftProtobufError.BinaryDecoding {
  /// If a read/write to the stream fails, but the stream's `streamError` is nil,
  /// this error will be thrown instead since the stream didn't provide anything
  /// more specific. A common cause for this can be failing to open the stream
  /// before trying to read/write to it.
  public static let unknownStreamError = SwiftProtobufError(
    code: .binaryDecodingError,
    message: "Unknown error when reading/writing binary-delimited message into stream."
  )
  
  /// While attempting to read the length of a message on the stream, the
  /// bytes were malformed for the protobuf format.
  public static let malformedLength = SwiftProtobufError(
    code: .binaryDecodingError,
    message: """
      While attempting to read the length of a binary-delimited message \
      on the stream, the bytes were malformed for the protobuf format.
    """
  )
  
  /// This isn't really an error. `InputStream` documents that
  /// `hasBytesAvailable` _may_ return `True` if a read is needed to
  /// determine if there really are bytes available. So this "error" is thrown
  /// when a `parse` or `merge` fails because there were no bytes available.
  /// If this is raised, the callers should decide via what ever other means
  /// are correct if the stream has completely ended or if more bytes might
  /// eventually show up.
  public static let noBytesAvailable = SwiftProtobufError(
    code: .binaryDecodingError,
    message: """
      This is not really an error: please read the documentation for
      `SwiftProtobufError/BinaryDecoding/noBytesAvailable` for more information.
    """
  )
}

/// Helper methods for reading/writing messages with a length prefix.
public enum BinaryDelimited {
  /// Additional errors for delimited message handing.
  @available(*, deprecated, message: "This error type has been deprecated and won't be thrown anymore; it has been replaced by `SwiftProtobufError`.")
  public enum Error: Swift.Error {
    /// If a read/write to the stream fails, but the stream's `streamError` is nil,
    /// this error will be throw instead since the stream didn't provide anything
    /// more specific. A common cause for this can be failing to open the stream
    /// before trying to read/write to it.
    case unknownStreamError

    /// While reading/writing to the stream, less than the expected bytes was
    /// read/written.
    case truncated

    /// Messages are limited by the protobuf spec to 2GB; when decoding, if the
    /// length says the payload is over 2GB, this error is raised.
    case tooLarge

    /// While attempting to read the length of a message on the stream, the
    /// bytes were malformed for the protobuf format.
    case malformedLength

    /// This isn't really an "error". `InputStream` documents that
    /// `hasBytesAvailable` _may_ return `True` if a read is needed to
    /// determine if there really are bytes available. So this "error" is throw
    /// when a `parse` or `merge` fails because there were no bytes available.
    /// If this is rasied, the callers should decides via what ever other means
    /// are correct if the stream has completely ended or if more bytes might
    /// eventually show up.
    case noBytesAvailable
  }

#if !os(WASI)
  /// Serialize a single size-delimited message to the given stream. Delimited
  /// format allows a single file or stream to contain multiple messages,
  /// whereas normally writing multiple non-delimited messages to the same
  /// stream would cause them to be merged. A delimited message is a varint
  /// encoding the message size followed by a message of exactly that size.
  ///
  /// - Parameters:
  ///   - message: The message to be written.
  ///   - to: The `OutputStream` to write the message to.  The stream is
  ///     is assumed to be ready to be written to.
  ///   - partial: If `false` (the default), this method will check
  ///     ``Message/isInitialized-6abgi`` before encoding to verify that all required
  ///     fields are present. If any are missing, this method throws
  ///     ``SwiftProtobufError/BinaryEncoding/missingRequiredFields``.
  /// - Throws: ``SwiftProtobufError`` if encoding fails or some writing errors occur; or the
  ///           underlying `OutputStream.streamError` for a stream error.
  public static func serialize(
    message: any Message,
    to stream: OutputStream,
    partial: Bool = false
  ) throws {
    // TODO: Revisit to avoid the extra buffering when encoding is streamed in general.
    let serialized: [UInt8] = try message.serializedBytes(partial: partial)
    let totalSize = Varint.encodedSize(of: UInt64(serialized.count)) + serialized.count
    var bytes: [UInt8] = Array(repeating: 0, count: totalSize)
    bytes.withUnsafeMutableBytes { (body: UnsafeMutableRawBufferPointer) in
      var encoder = BinaryEncoder(forWritingInto: body)
      encoder.putBytesValue(value: serialized)
    }

    var written: Int = 0
    bytes.withUnsafeBytes { (body: UnsafeRawBufferPointer) in
      if let baseAddress = body.baseAddress, body.count > 0 {
        // This assumingMemoryBound is technically unsafe, but without SR-11078
        // (https://bugs.swift.org/browse/SR-11087) we don't have another option.
        // It should be "safe enough".
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        written = stream.write(pointer, maxLength: totalSize)
      }
    }

    if written != totalSize {
      if written == -1 {
        if let streamError = stream.streamError {
          throw streamError
        }
        throw SwiftProtobufError.BinaryDecoding.unknownStreamError
      }
      throw SwiftProtobufError.BinaryEncoding.truncated
    }
  }

  /// Reads a single size-delimited message from the given stream. Delimited
  /// format allows a single file or stream to contain multiple messages,
  /// whereas normally parsing consumes the entire input. A delimited message
  /// is a varint encoding the message size followed by a message of exactly
  /// exactly that size.
  ///
  /// - Parameters:
  ///   - messageType: The type of message to read.
  ///   - from: The `InputStream` to read the data from.  The stream is assumed
  ///     to be ready to read from.
  ///   - extensions: An ``ExtensionMap`` used to look up and decode any
  ///     extensions in this message or messages nested within this message's
  ///     fields.
  ///   - partial: If `false` (the default), this method will check
  ///     ``Message/isInitialized-6abgi`` after decoding to verify that all required
  ///     fields are present. If any are missing, this method throws
  ///     ``SwiftProtobufError/BinaryDecoding/missingRequiredFields``.
  ///   - options: The ``BinaryDecodingOptions`` to use.
  /// - Returns: The message read.
  /// - Throws: ``SwiftProtobufError`` if decoding fails, and for some reading errors; or the
  ///           underlying `InputStream.streamError` for a stream error.
  public static func parse<M: Message>(
    messageType: M.Type,
    from stream: InputStream,
    extensions: (any ExtensionMap)? = nil,
    partial: Bool = false,
    options: BinaryDecodingOptions = BinaryDecodingOptions()
  ) throws -> M {
    var message = M()
    try merge(into: &message,
              from: stream,
              extensions: extensions,
              partial: partial,
              options: options)
    return message
  }

  /// Updates the message by reading a single size-delimited message from
  /// the given stream. Delimited format allows a single file or stream to
  /// contain multiple messages, whereas normally parsing consumes the entire
  /// input. A delimited message is a varint encoding the message size
  /// followed by a message of exactly that size.
  ///
  /// - Note: If this method throws an error, the message may still have been
  ///   partially mutated by the binary data that was decoded before the error
  ///   occurred.
  ///
  /// - Parameters:
  ///   - mergingTo: The message to merge the data into.
  ///   - from: The `InputStream` to read the data from.  The stream is assumed
  ///     to be ready to read from.
  ///   - extensions: An ``ExtensionMap`` used to look up and decode any
  ///     extensions in this message or messages nested within this message's
  ///     fields.
  ///   - partial: If `false` (the default), this method will check
  ///     ``Message/isInitialized-6abgi`` after decoding to verify that all required
  ///     fields are present. If any are missing, this method throws
  ///     ``SwiftProtobufError/BinaryDecoding/missingRequiredFields``.
  ///   - options: The BinaryDecodingOptions to use.
  /// - Throws: ``SwiftProtobufError`` if decoding fails, and for some reading errors; or the
  ///           underlying `InputStream.streamError` for a stream error.
  public static func merge<M: Message>(
    into message: inout M,
    from stream: InputStream,
    extensions: (any ExtensionMap)? = nil,
    partial: Bool = false,
    options: BinaryDecodingOptions = BinaryDecodingOptions()
  ) throws {
    let unsignedLength = try decodeVarint(stream)
    if unsignedLength == 0 {
      // The message was all defaults, nothing to actually read.
      return
    }
    guard unsignedLength <= 0x7fffffff else {
      throw SwiftProtobufError.BinaryDecoding.tooLarge
    }
    let length = Int(unsignedLength)

    // TODO: Consider doing a version with getBuffer:length: if the InputStream
    // support it and thus avoiding this local copy.

    // Even though the bytes are read in chunks, things can still hard fail if
    // there isn't enough memory to append to have all the bytes at once for
    // parsing.
    var data = [UInt8]()
    let kChunkSize = 16 * 1024 * 1024
    var chunk = [UInt8](repeating: 0, count: min(length, kChunkSize))
    var bytesNeeded = length
    while bytesNeeded > 0 {
      let maxLength = min(bytesNeeded, chunk.count)
      var bytesRead: Int = 0
      chunk.withUnsafeMutableBytes { (body: UnsafeMutableRawBufferPointer) in
        if let baseAddress = body.baseAddress, body.count > 0 {
          let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
          bytesRead = stream.read(pointer, maxLength: maxLength)
        }
      }
      if bytesRead == -1 {
        if let streamError = stream.streamError {
          throw streamError
        }
        throw SwiftProtobufError.BinaryDecoding.unknownStreamError
      }
      if bytesRead == 0 {
        // Hit the end of the stream
        throw SwiftProtobufError.BinaryDecoding.truncated
      }
      if bytesRead < chunk.count {
        data += chunk[0..<bytesRead]
      } else {
        data += chunk
      }
      bytesNeeded -= bytesRead
    }

    try message.merge(serializedBytes: data,
                      extensions: extensions,
                      partial: partial,
                      options: options)
  }
#endif  // !os(WASI)
}

#if !os(WASI)
// TODO: This should go away when encoding/decoding are more stream based
// as that should provide a more direct way to do this. This is basically
// a rewrite of BinaryDecoder.decodeVarint().
internal func decodeVarint(_ stream: InputStream) throws -> UInt64 {

  // Buffer to reuse within nextByte.
  let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
  defer { readBuffer.deallocate() }

  func nextByte() throws -> UInt8? {
    let bytesRead = stream.read(readBuffer, maxLength: 1)
    switch bytesRead {
    case 1:
      return readBuffer[0]
    case 0:
      return nil
    default:
      precondition(bytesRead == -1)
      if let streamError = stream.streamError {
        throw streamError
      }
      throw SwiftProtobufError.BinaryDecoding.unknownStreamError
    }
  }

  var value: UInt64 = 0
  var shift: UInt64 = 0
  while true {
    guard let c = try nextByte() else {
      if shift == 0 {
        throw SwiftProtobufError.BinaryDecoding.noBytesAvailable
      }
      throw SwiftProtobufError.BinaryDecoding.truncated
    }
    value |= UInt64(c & 0x7f) << shift
    if c & 0x80 == 0 {
      return value
    }
    shift += 7
    if shift > 63 {
      throw SwiftProtobufError.BinaryDecoding.malformedLength
    }
  }
}
#endif  // !os(WASI)
