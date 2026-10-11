import Foundation

// SwiftUI only localizes literals, so model strings go through here. The key is the English text with
// {0}, {1}... where values were interpolated.
enum L10n {
    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []

            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            mutating func appendLiteral(_ literal: String) { key += literal }

            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }

    static func tr(_ message: Message, in bundle: Bundle = .module) -> String {
        render(bundle.localizedString(forKey: message.key, value: message.key, table: nil), arguments: message.arguments)
    }

    // One pass, so a value containing "{1}" is never substituted again.
    static func render(_ template: String, arguments: [String]) -> String {
        var result = ""
        var position = template.startIndex
        for match in template.matches(of: /\{([0-9]+)\}/) {
            result += template[position ..< match.range.lowerBound]
            if let index = Int(match.1), arguments.indices.contains(index) {
                result += arguments[index]
            } else {
                result += template[match.range]
            }
            position = match.range.upperBound
        }
        return result + template[position...]
    }
}
