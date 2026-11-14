// The one Foundation import for the module. Android gets FoundationEssentials, which leaves out ICU.
// Other files in this module import nothing from Foundation; check.sh enforces it.
#if canImport(FoundationEssentials)
@_exported import FoundationEssentials
#if canImport(Android)
@_exported import Android
#elseif canImport(Glibc)
@_exported import Glibc
#endif
#else
@_exported import Foundation
#endif

extension String {
    /// Drops leading and trailing whitespace and newlines.
    var trimmed: String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
