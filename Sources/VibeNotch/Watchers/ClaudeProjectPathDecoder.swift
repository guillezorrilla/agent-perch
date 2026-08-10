import Foundation

enum ClaudeProjectPathDecoder {
    static func decode(
        _ encoded: String,
        exists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String {
        guard encoded.hasPrefix("-") else { return encoded }

        let pieces = encoded.dropFirst().split(
            separator: "-",
            omittingEmptySubsequences: false
        ).map(String.init)

        func resolve(from index: Int, beneath parent: String) -> String? {
            guard index < pieces.count else { return exists(parent) ? parent : nil }

            var component = ""
            for end in index..<pieces.count {
                if end > index { component += "-" }
                component += pieces[end]
                guard !component.isEmpty else { continue }

                let candidate = parent == "/"
                    ? "/\(component)"
                    : "\(parent)/\(component)"
                if exists(candidate),
                   let resolved = resolve(from: end + 1, beneath: candidate) {
                    return resolved
                }
            }
            return nil
        }

        return resolve(from: 0, beneath: "/") ?? encoded
    }
}
