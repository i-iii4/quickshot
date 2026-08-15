import CoreGraphics
import Foundation

@main
struct SensitiveDataTests {
    static func main() {
        findsObviousSecrets()
        luhnRejectsRandomLongNumbers()
        doesNotFireOnOrdinaryText()
        rectConversionFlipsAxis()
        everyKindHasATitle()
        print("SensitiveDataTests: passed")
    }

    /// `E-6`
    private static func findsObviousSecrets() {
        expectKind(.email, in: "write to anna.smith@example.com today")
        expectKind(.ipAddress, in: "server at 192.168.1.14 is down")
        expectKind(.token, in: "export KEY=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        expectKind(.userPath, in: "saved to /Users/sergey/Documents/report.pdf")
        // Тестовый номер Visa: валиден по Луну, реальному человеку не принадлежит.
        expectKind(.creditCard, in: "card 4111 1111 1111 1111 expires soon")
    }

    /// Без проверки Луна под правило попадали бы любые длинные числа: номера
    /// заказов, идентификаторы, серийники.
    private static func luhnRejectsRandomLongNumbers() {
        expect(SensitivePatterns.passesLuhn("4111111111111111"), "a valid test card passes")
        expect(!SensitivePatterns.passesLuhn("1234567890123456"),
               "a random 16-digit number must not be treated as a card")
        expect(!SensitivePatterns.passesLuhn("123456"), "too short to be a card")

        let matches = SensitivePatterns.matches(in: "order 1234567890123456 shipped")
        expect(!matches.contains { $0.kind == .creditCard },
               "an order number must not be reported as a card")
    }

    /// Ложное срабатывание закрывает нужное содержимое и подрывает доверие ко
    /// всей функции, поэтому обычный текст обязан оставаться нетронутым.
    /// `E-7`, `E-8`
    private static func doesNotFireOnOrdinaryText() {
        let ordinary = "The build finished in 12.4 seconds with 3 warnings."
        let matches = SensitivePatterns.matches(in: ordinary)
        expect(matches.isEmpty, "ordinary text must not match anything; got \(matches.map(\.kind))")

        let version = "QuickShot 1.2.3 released"
        expect(!SensitivePatterns.matches(in: version).contains { $0.kind == .ipAddress },
               "a version number is not an IP address")
    }

    /// Vision считает от нижнего левого угла, документ — от верхнего левого.
    private static func rectConversionFlipsAxis() {
        let normalized = CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.125)
        let rect = SensitiveDataDetector.documentRect(for: normalized,
                                                      imageSize: CGSize(width: 400, height: 800))
        expect(rect.origin.x == 100, "x scales directly; got \(rect.origin.x)")
        expect(rect.width == 200 && rect.height == 100, "size scales; got \(rect.size)")
        expect(rect.origin.y == 100,
               "y flips: a box near the top in Vision is near the top in the document; got \(rect.origin.y)")
    }

    private static func everyKindHasATitle() {
        for kind in SensitiveKind.allCases {
            expect(!kind.title.isEmpty, "\(kind) must be nameable in the interface")
        }
    }

    private static func expectKind(_ kind: SensitiveKind, in text: String) {
        let matches = SensitivePatterns.matches(in: text)
        expect(matches.contains { $0.kind == kind },
               "\(kind) not found in \"\(text)\"; got \(matches.map(\.kind))")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("SensitiveDataTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
