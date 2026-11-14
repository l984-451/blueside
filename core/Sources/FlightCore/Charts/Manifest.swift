public enum ManifestError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalid(String)
}

public struct Manifest: Equatable, Sendable, Decodable {
    public static let supportedVersion = 1

    public var version: Int
    public var cycles: [Cycle]

    public struct Cycle: Equatable, Sendable, Decodable {
        public var id: String
        public var effective: Date
        public var expires: Date
        public var packs: [Pack]
    }

    public struct Pack: Equatable, Sendable, Decodable {
        public var layer: String
        public var region: String
        public var path: String
        public var bytes: Int
        public var sha256: String

        public init(layer: String, region: String, path: String, bytes: Int, sha256: String) {
            self.layer = layer
            self.region = region
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    /// Decodes and validates. The manifest comes from the network, so nothing in it is trusted.
    public static func decode(_ data: Data) throws -> Manifest {
        struct VersionOnly: Decodable { var version: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version = try decoder.decode(VersionOnly.self, from: data).version
        guard version == supportedVersion else { throw ManifestError.unsupportedVersion(version) }
        var manifest = try decoder.decode(Manifest.self, from: data)
        // Cycle-free packs, listed once. Each cycle offers them, in place of any copy of its own.
        struct BaseOnly: Decodable { var base: [Pack]? }
        let base = try decoder.decode(BaseOnly.self, from: data).base ?? []
        try manifest.validate(base: base)
        let names = Set(base.map { [$0.layer, $0.region] })
        for index in manifest.cycles.indices {
            manifest.cycles[index].packs.removeAll { names.contains([$0.layer, $0.region]) }
            manifest.cycles[index].packs += base
        }
        return manifest
    }

    private func validate(base: [Pack]) throws {
        guard Set(cycles.map(\.id)).count == cycles.count else { throw ManifestError.invalid("duplicate cycle id") }
        guard Set(cycles.map(\.effective)).count == cycles.count else { throw ManifestError.invalid("duplicate cycle date") }
        let paths = cycles.flatMap { $0.packs.map(\.path) } + base.map(\.path)
        guard Set(paths).count == paths.count else { throw ManifestError.invalid("duplicate pack path") }
        for cycle in cycles {
            guard Self.isToken(cycle.id) else { throw ManifestError.invalid("cycle id") }
            guard cycle.expires > cycle.effective else { throw ManifestError.invalid("cycle dates") }
        }
        for packs in cycles.map(\.packs) + [base] {
            let names = packs.map { $0.layer + "/" + $0.region }
            guard Set(names).count == names.count else { throw ManifestError.invalid("duplicate pack") }
            for pack in packs {
                guard Self.isToken(pack.layer), Self.isToken(pack.region) else { throw ManifestError.invalid("pack name") }
                guard Self.isSafePath(pack.path) else { throw ManifestError.invalid("pack path") }
                guard pack.bytes > 0 else { throw ManifestError.invalid("pack size") }
                guard Self.isSHA256(pack.sha256) else { throw ManifestError.invalid("pack checksum") }
            }
        }
    }

    private static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // Relative, forward slashes only, no empty, "." or ".." components.
    private static func isSafePath(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("/") else { return false }
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }) else { return false }
        return !s.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }
}

extension Manifest {
    /// The newest cycle already in effect.
    public func currentCycle(at now: Date) -> Cycle? {
        cycles.filter { $0.effective <= now }.max { $0.effective < $1.effective }
    }

    /// The earliest cycle not yet in effect.
    public func nextCycle(at now: Date) -> Cycle? {
        cycles.filter { $0.effective > now }.min { $0.effective < $1.effective }
    }
}
