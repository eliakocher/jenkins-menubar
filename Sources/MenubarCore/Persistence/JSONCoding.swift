import Foundation

/// The JSON style of every file the app keeps: indented with sorted keys, so a file reads well and changes little
/// between writes.
///
/// Dates are encoded as Foundation's own number (seconds since 2001), which reads back exactly. ISO 8601 text would be
/// easier to read, but drops the bits below a millisecond, so a build read back from the cache would no longer equal
/// the same build from Jenkins.
enum JSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
