//
//  SummaryDocument.swift
//  AuraVoice
//
//  Özet markdown'ını yapısal bölümlere ayırır.
//
//  NEDEN: Mockup özeti tek bir metin bloğu olarak değil, ayrı kartlar
//  ("Ana Başlıklar", "Kararlar", "Aksiyonlar") olarak gösteriyor. Bunu
//  çizebilmek için markdown'ı ayrıştırmak gerekiyor.
//
//  Markdown yine de TEK DOĞRULUK KAYNAĞI olarak kalıyor: aksiyon kutusu
//  işaretlendiğinde markdown'daki `- [ ]` → `- [x]` olarak yeniden yazılıp
//  kaydediliyor. Böylece paylaşma, dışa aktarma ve olası bulut senkronu
//  ayrı bir durum modeliyle uğraşmak zorunda kalmıyor.
//

import Foundation

public struct SummaryDocument: Sendable, Equatable {

    public enum Item: Sendable, Equatable {
        case bullet(String)
        case task(text: String, isDone: Bool)

        public var text: String {
            switch self {
            case let .bullet(text):      return text
            case let .task(text, _):     return text
            }
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public let id: Int
        public let title: String
        public let items: [Item]

        public var containsTasks: Bool {
            items.contains { if case .task = $0 { return true } else { return false } }
        }
    }

    /// `### ...` satırı.
    public let title: String?
    /// `_..._` ile yazılmış meta satırı (mod, süre).
    public let meta: String?
    public let sections: [Section]
    /// Hiçbir bölüme girmeyen serbest satırlar.
    public let looseItems: [Item]

    public var isEmpty: Bool {
        sections.isEmpty && looseItems.isEmpty
    }

    // MARK: - Ayrıştırma

    public static func parse(_ markdown: String) -> SummaryDocument {
        var title: String?
        var meta: String?
        var sections: [Section] = []
        var loose: [Item] = []

        var currentTitle: String?
        var currentItems: [Item] = []
        var sectionIndex = 0

        func closeSection() {
            guard let currentTitle else {
                loose.append(contentsOf: currentItems)
                currentItems = []
                return
            }
            sections.append(Section(id: sectionIndex, title: currentTitle, items: currentItems))
            sectionIndex += 1
            currentItems = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                // Başlık: ilk gördüğümüzü belge başlığı sayıyoruz.
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if title == nil { title = text } else { closeSection(); currentTitle = text }

            } else if let bold = boldHeading(line) {
                closeSection()
                currentTitle = bold

            } else if let task = parseTask(line) {
                currentItems.append(task)

            } else if let bullet = parseBullet(line) {
                currentItems.append(.bullet(bullet))

            } else if line.hasPrefix("_"), line.hasSuffix("_"), line.count > 2 {
                if meta == nil { meta = String(line.dropFirst().dropLast()) }

            } else {
                // Düz paragraf da madde sayılır; özet formatı bozuk gelse
                // bile içerik ekranda görünsün.
                currentItems.append(.bullet(line))
            }
        }
        closeSection()

        return SummaryDocument(title: title, meta: meta, sections: sections, looseItems: loose)
    }

    /// `**Kararlar**` biçimindeki bölüm başlığı.
    static func boldHeading(_ line: String) -> String? {
        guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { return nil }
        return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    /// `- [ ] metin` veya `- [x] metin`.
    static func parseTask(_ line: String) -> Item? {
        let markers = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "]
        for marker in markers where line.hasPrefix(marker) {
            let isDone = marker.lowercased().contains("[x]")
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .task(text: text, isDone: isDone)
        }
        return nil
    }

    /// `- metin` veya `* metin`.
    static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Görev işaretleme

    /// Metni eşleşen ilk görev kutusunu ters çevirip yeni markdown'ı döner.
    ///
    /// Satır numarası yerine metinle eşleştiriyoruz: ayrıştırma sırasında
    /// boş satırlar atlandığı için indeksler markdown'ın satır numaralarıyla
    /// birebir örtüşmüyor.
    public static func toggleTask(withText text: String, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        let needle = text.trimmingCharacters(in: .whitespaces)

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let item = parseTask(line), case let .task(itemText, isDone) = item,
                  itemText == needle
            else { continue }

            let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
            lines[index] = "\(leading)- [\(isDone ? " " : "x")] \(itemText)"
            break
        }
        return lines.joined(separator: "\n")
    }

    /// Tamamlanan / toplam görev sayısı.
    public static func taskProgress(in markdown: String) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for rawLine in markdown.components(separatedBy: .newlines) {
            guard let item = parseTask(rawLine.trimmingCharacters(in: .whitespaces)),
                  case let .task(_, isDone) = item
            else { continue }
            total += 1
            if isDone { done += 1 }
        }
        return (done, total)
    }
}
