import Foundation

/// Renders the bilingual trend report with embedded data and charts. No process or network calls.
public enum UsageReportHTMLRenderer {
    public static func render(_ snapshot: UsageReportSnapshot) throws -> String {
        let template = try Self.resource("trend", extension: "html")
        let colors = try Self.resource("dark-tokens", extension: "js")
        let helpers = try Self.resource("mono-tokens", extension: "js")
        let charts = try Self.resource("render", extension: "js")
        let stylesheet = try Self.resource("common", extension: "css")
        let toolbar = try Self.resource("toolbar", extension: "html")
        let details = try Self.resource("details", extension: "html")
        let chartLibrary = try Self.resource("chart.umd.min", extension: "js")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        let replacements: [String: String] = [
            "HEAD_BUNDLE": "<script>\(colors)\n"
                + "const CHART_THEME=CHART.palette('palm');CHART.install(CHART_THEME);\n"
                + "\(helpers)</script><script>\(chartLibrary)</script>",
            "COMMON_STYLE": "<style>\(stylesheet)</style>",
            "TOOLBAR": toolbar,
            "DATA_DETAILS": details,
            "SCRIPT_BUNDLE": "<script>const REPORT=\(json);\n/* Report runtime */\n\(charts)</script>",
        ]

        // Replace only tokens in the trusted template. Inserted model names are never parsed as tokens.
        let expression = try NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#)
        let source = template as NSString
        let matches = expression.matches(in: template, range: NSRange(location: 0, length: source.length))
        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = source.substring(with: match.range(at: 1))
            guard let value = replacements[key] else { throw RenderError.unknownPlaceholder(key) }
            result += value
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func resource(_ name: String, extension suffix: String) throws -> String {
        // Packaged apps keep SwiftPM resources in Contents/Resources. Resolve them there first
        // so a distributed app never relies on SwiftPM's absolute development-build fallback.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("QuotaBar_QuotaBarCore.bundle")
        let resourceBundle = bundled.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resourceBundle.url(forResource: name, withExtension: suffix, subdirectory: "UsageReport") else {
            throw RenderError.missingResource("\(name).\(suffix)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private enum RenderError: LocalizedError {
        case missingResource(String)
        case unknownPlaceholder(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "The report template is missing \(name). Reinstall QuotaBar and try again."
            case .unknownPlaceholder(let key): "The report template contains an unsupported field: \(key)."
            }
        }
    }
}
