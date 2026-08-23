import CoreGraphics
import Foundation
import Vision

/// Что именно нашли на снимке. Тип нужен, чтобы показать пользователю, что
/// будет скрыто: молчаливое закрытие запрещено (`E-7`).
enum SensitiveKind: String, CaseIterable {
    case email
    case phone
    case creditCard
    case ipAddress
    case token
    case userPath

    var title: String {
        switch self {
        case .email: return "Email"
        case .phone: return "Phone"
        case .creditCard: return "Card number"
        case .ipAddress: return "IP address"
        case .token: return "Token"
        case .userPath: return "User path"
        }
    }
}

struct SensitiveMatch: Equatable {
    let kind: SensitiveKind
    let text: String
    /// Нормализованный прямоугольник Vision: начало координат внизу слева.
    let normalizedRect: CGRect
}

/// Поиск чувствительных данных в распознанном тексте.
///
/// Правила намеренно консервативны: ложное срабатывание закрывает нужное
/// пользователю содержимое, и он теряет доверие ко всей функции. Пропуск же
/// исправляется вручную — поэтому при сомнении лучше не находить.
enum SensitivePatterns {
    /// Номер карты: 13–19 цифр с пробелами или дефисами, проверенные Луном.
    /// Без проверки контрольной суммы под правило попадали бы любые длинные
    /// числа — номера заказов, идентификаторы, телефоны.
    static func matches(in text: String) -> [(kind: SensitiveKind, range: Range<String.Index>)] {
        var found: [(SensitiveKind, Range<String.Index>)] = []
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                let value = String(text[range])
                if kind == .creditCard, !passesLuhn(value) { return }
                found.append((kind, range))
            }
        }
        return found
    }

    private static let patterns: [(SensitiveKind, String)] = [
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        (.creditCard, #"\b(?:\d[ -]*?){13,19}\b"#),
        (.ipAddress, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
        (.phone, #"(?:\+\d{1,3}[ -]?)?\(?\d{3}\)?[ -]?\d{3}[ -]?\d{2}[ -]?\d{2}\b"#),
        (.token, #"\b(?:sk|pk|ghp|gho|xox[baprs])[-_][A-Za-z0-9_-]{16,}\b"#),
        (.userPath, #"/Users/[A-Za-z0-9._-]+"#),
    ]

    /// Контрольная сумма Луна: отсекает длинные числа, не являющиеся картами.
    static func passesLuhn(_ value: String) -> Bool {
        let digits = value.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// Обнаружение чувствительных данных на снимке системным распознаванием текста
/// (`E-6`).
///
/// Это распознавание текста, а не элементов интерфейса: отклонение умных
/// инструментов (`X-2`) сюда не распространяется, и всё считается на машине —
/// снимок никуда не уходит.
enum SensitiveDataDetector {
    static func detect(in image: CGImage) async -> [SensitiveMatch] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: sensitiveMatches(in: observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Совпадения по всем распознанным строкам.
    private static func sensitiveMatches(in observations: [VNRecognizedTextObservation]) -> [SensitiveMatch] {
        observations.flatMap { observation -> [SensitiveMatch] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            return sensitiveMatches(in: candidate, fallbackBox: observation.boundingBox)
        }
    }

    /// Совпадения в одной строке. Прямоугольник берётся именно у найденного
    /// фрагмента, а не у всей строки: закрывать строку целиком значит прятать
    /// лишнее.
    private static func sensitiveMatches(in candidate: VNRecognizedText,
                                         fallbackBox: CGRect) -> [SensitiveMatch] {
        let text = candidate.string
        return SensitivePatterns.matches(in: text).map { kind, range in
            let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? fallbackBox
            return SensitiveMatch(kind: kind,
                                  text: String(text[range]),
                                  normalizedRect: box)
        }
    }

    /// Перевод нормализованного прямоугольника Vision в координаты документа.
    /// Vision считает от нижнего левого угла, документ — от верхнего левого.
    static func documentRect(for normalized: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: normalized.minX * imageSize.width,
               y: (1 - normalized.maxY) * imageSize.height,
               width: normalized.width * imageSize.width,
               height: normalized.height * imageSize.height)
    }
}
