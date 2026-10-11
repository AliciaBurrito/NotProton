import Foundation
import Testing

@testable import NotProtonApp

@Suite("Localization")
struct LocalizationTests {
    let chinese = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Chinese text is looked up with interpolated values in place")
    func chineseLookup() throws {
        let zh = try #require(chinese)
        #expect(L10n.tr("Status", in: zh) == "状态")
        #expect(L10n.tr("Delete \(3) prefixes?", in: zh) == "删除 3 个游戏容器？")
    }

    @Test("Missing translations fall back to the English text")
    func fallback() throws {
        let zh = try #require(chinese)
        #expect(L10n.tr("Untranslated \(42)", in: zh) == "Untranslated 42")
    }

    @Test("Interpolated values are inserted once and never reinterpreted")
    func valuesStayLiteral() {
        #expect(L10n.render("{1}/{0}/{1}", arguments: ["{1}", "100%"]) == "100%/{1}/100%")
        #expect(L10n.render("{9} {0}", arguments: ["safe"]) == "{9} safe")
    }
}
