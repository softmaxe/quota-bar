import Foundation
import JavaScriptCore
import QuotaBarCore

/// Runs the report's actual startup selection in JavaScriptCore, without requiring a browser.
enum UsageReportLanguageTests {
    static func run() {
        do {
            let html = try UsageReportHTMLRenderer.render(UsageReportSnapshot(days: []))
            guard let start = html.range(of: "  let stored={};")?.lowerBound,
                  let end = html.range(of: "  metric=(params.get('metric')", range: start..<html.endIndex)?.lowerBound else {
                Harness.expect(false, "report language startup was not found")
                return
            }
            let startup = String(html[start..<end])
            let cases: [(String, String?, String, String)] = [
                ("en-US", nil, "", "en"), ("zh-Hans-CN", nil, "", "zh"),
                ("zh-Hant-TW", nil, "", "zh"), ("ja-JP", nil, "", "en"),
                ("en-US", "zh", "", "zh"), ("zh-CN", "en", "", "en"),
                ("zh-CN", "zh", "?lang=en", "en"), ("en-US", "en", "?lang=zh", "zh"),
            ]
            for (system, stored, query, expected) in cases {
                let context = JSContext()!
                context.evaluateScript("""
                    var language, STORE='test';
                    var navigator={language:'\(system)',languages:['\(system)','zh-CN']};
                    var location={search:'\(query)'};
                    var localStorage={getItem:()=>JSON.stringify({language:\(stored.map { "'\($0)'" } ?? "null")})};
                    function URLSearchParams(query){this.get=key=>query==='?lang=en'?'en':query==='?lang=zh'?'zh':null;}
                    """)
                context.evaluateScript(startup)
                Harness.expect(context.exception == nil, "report language startup executes")
                Harness.expectEqual(context.objectForKeyedSubscript("language")?.toString(), expected,
                                    "language priority is query, saved choice, then the first system preference")
            }
        } catch {
            Harness.expect(false, "report language check threw: \(error)")
        }
    }
}
