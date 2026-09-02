//
//  MinuteTicket.swift
//  AuraVoice
//
//  Ed25519 imzalı dakika bileti.
//
//  NEDEN: Kota bakiyesi cihazda tutuluyor ve uygulama offline çalışabiliyor.
//  Bakiyeyi yalnızca Keychain'de saklamak "sunucuya sormadan dakika ekleme"
//  girişimini engellemez. Bilet, dakikanın SUNUCUDAN geldiğini kanıtlıyor:
//  özel anahtar hiçbir zaman cihaza inmiyor, uygulamada yalnızca doğrulama
//  yapan açık anahtar var.
//
//  KANONİK İMZA GÖVDESİ — sunucu tarafı bunu birebir üretmek zorunda.
//  Alanlar '|' ile birleştirilir, UTF-8 olarak kodlanır ve imzalanır:
//
//      aura.ticket.v1|<id>|<subject>|<plan>|<milliminutes>|<issuedAtMs>|<expiresAtMs>
//
//  · milliminutes : dakikanın binde biri, tamsayı  → Int64((minutes*1000).rounded())
//  · issuedAtMs   : epoch'tan beri milisaniye, tamsayı
//  · expiresAtMs  : epoch'tan beri milisaniye, tamsayı
//
//  Ondalık ayraç ve tarih biçimi tartışması olmasın diye her sayısal alan
//  tamsayıya indirgendi; yerel ayarların imzayı bozması mümkün değil.
//

import Foundation
import CryptoKit

// MARK: - Bilet

public struct MinuteTicket: Sendable, Equatable {

    public static let version = "aura.ticket.v1"

    /// Tekrar kullanımı engelleyen tekil kimlik (nonce).
    public let id: String
    /// Biletin geçerli olduğu cihaz/hesap. "*" her cihaz demek (yalnızca geliştirme).
    public let subject: String
    /// Abonelik planı etiketi — kayıt ve destek için, doğrulamada rol oynamaz.
    public let plan: String
    public let minutes: Double
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: String,
        subject: String,
        plan: String,
        minutes: Double,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.subject = subject
        self.plan = plan
        self.minutes = minutes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    // MARK: Kanonik gövde

    public var milliMinutes: Int64 { Int64((minutes * 1000).rounded()) }
    public var issuedAtMillis: Int64 { MinuteTicket.millis(from: issuedAt) }
    public var expiresAtMillis: Int64 { MinuteTicket.millis(from: expiresAt) }

    /// İmzalanan baytlar. Sunucu birebir aynısını üretmeli.
    public var canonicalPayload: Data {
        let joined = [
            Self.version,
            id,
            subject,
            plan,
            String(milliMinutes),
            String(issuedAtMillis),
            String(expiresAtMillis)
        ].joined(separator: "|")
        return Data(joined.utf8)
    }

    public static func millis(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func date(fromMillis millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

// MARK: JSON aktarımı

extension MinuteTicket: Codable {

    private enum CodingKeys: String, CodingKey {
        case id, subject, plan, minutes, issuedAtMs, expiresAtMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.subject = try container.decode(String.self, forKey: .subject)
        self.plan = try container.decodeIfPresent(String.self, forKey: .plan) ?? ""
        self.minutes = try container.decode(Double.self, forKey: .minutes)
        self.issuedAt = MinuteTicket.date(fromMillis: try container.decode(Int64.self, forKey: .issuedAtMs))
        self.expiresAt = MinuteTicket.date(fromMillis: try container.decode(Int64.self, forKey: .expiresAtMs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(subject, forKey: .subject)
        try container.encode(plan, forKey: .plan)
        try container.encode(minutes, forKey: .minutes)
        try container.encode(issuedAtMillis, forKey: .issuedAtMs)
        try container.encode(expiresAtMillis, forKey: .expiresAtMs)
    }
}

// MARK: - İmzalı bilet

public struct SignedTicket: Sendable, Equatable, Codable {

    public let ticket: MinuteTicket
    /// Base64 kodlanmış 64 baytlık Ed25519 imzası.
    public let signature: String

    public init(ticket: MinuteTicket, signature: String) {
        self.ticket = ticket
        self.signature = signature
    }

    public var signatureBytes: Data? {
        Data(base64Encoded: signature)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SignedTicket {
        do {
            return try JSONDecoder().decode(SignedTicket.self, from: data)
        } catch {
            throw TicketError.malformed
        }
    }
}

// MARK: - Hatalar

public enum TicketError: LocalizedError, Equatable {

    case malformed
    case unsupportedVersion
    case invalidSignature
    case expired(at: Date)
    case wrongDevice
    case nonPositiveMinutes
    case alreadyRedeemed
    case verifierUnavailable
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .malformed:
            return String(localized: "Dakika bileti okunamadı.")
        case .unsupportedVersion:
            return String(localized: "Bilet biçimi bu sürüm tarafından desteklenmiyor. Uygulamayı güncelleyin.")
        case .invalidSignature:
            return String(localized: "Dakika biletinin imzası geçersiz.")
        case .expired(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return String(localized: "Dakika biletinin süresi dolmuş (\(formatter.string(from: date))).")
        case .wrongDevice:
            return String(localized: "Bu dakika bileti başka bir cihaz için düzenlenmiş.")
        case .nonPositiveMinutes:
            return String(localized: "Bilet geçerli bir dakika miktarı içermiyor.")
        case .alreadyRedeemed:
            return String(localized: "Bu dakika bileti zaten kullanılmış.")
        case .verifierUnavailable:
            return String(localized: "Bilet doğrulama anahtarı bulunamadı.")
        case .storageUnavailable:
            return String(localized: "Bilet kaydı güvenli depoya yazılamadı, dakikalar eklenmedi.")
        }
    }
}

// MARK: - Doğrulayıcı

public struct TicketVerifier: Sendable {

    /// Info.plist anahtarı — base64 kodlanmış 32 baytlık Ed25519 açık anahtarı.
    public static let publicKeyInfoKey = "AuraTicketPublicKey"

    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    public init(publicKeyRaw: Data) throws {
        do {
            self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
        } catch {
            throw TicketError.verifierUnavailable
        }
    }

    public init(base64PublicKey: String) throws {
        guard let raw = Data(base64Encoded: base64PublicKey) else {
            throw TicketError.verifierUnavailable
        }
        try self.init(publicKeyRaw: raw)
    }

    /// Uygulamanın varsayılan doğrulayıcısı.
    ///
    /// Anahtar Info.plist'te taşınıyor: gizli değil (açık anahtar), ama
    /// derleme zamanı sabiti olması sunucu anahtarını değiştirmek için yeni
    /// bir sürüm gerektirdiği anlamına geliyor — kasıtlı.
    public static func makeDefault(bundle: Bundle = .main) -> TicketVerifier? {
        guard let value = bundle.object(forInfoDictionaryKey: publicKeyInfoKey) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return try? TicketVerifier(base64PublicKey: value)
    }

    // MARK: Doğrulama

    /// Biletin imzasını ve geçerliliğini denetler.
    ///
    /// - Parameter now: Güvenilir zaman. `SecureTicketStore` burada cihaz
    ///   saatini değil, saatin geri alınmasına dayanıklı değeri geçiyor.
    @discardableResult
    public func verify(_ signed: SignedTicket, subject: String, now: Date) throws -> MinuteTicket {

        let ticket = signed.ticket

        guard let signatureBytes = signed.signatureBytes, signatureBytes.count == 64 else {
            throw TicketError.malformed
        }
        guard publicKey.isValidSignature(signatureBytes, for: ticket.canonicalPayload) else {
            throw TicketError.invalidSignature
        }

        // İmza doğrulandıktan SONRA içerik denetimi: imzasız veriye bakıp
        // karar vermek doğrulamanın anlamını ortadan kaldırırdı.
        guard ticket.minutes > 0 else { throw TicketError.nonPositiveMinutes }
        guard ticket.subject == subject || ticket.subject == "*" else { throw TicketError.wrongDevice }
        guard ticket.expiresAt > ticket.issuedAt else { throw TicketError.malformed }
        guard ticket.expiresAt > now else { throw TicketError.expired(at: ticket.expiresAt) }

        return ticket
    }
}

// MARK: - İmzalayıcı (yalnızca test ve yerel geliştirme)

/// Üretimde özel anahtar SUNUCUDA durur ve cihaza asla inmez. Bu tip yalnızca
/// testlerin ve yerel geliştirmenin gerçek imza üretebilmesi için var.
public struct TicketSigner: Sendable {

    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    public var verifier: TicketVerifier {
        TicketVerifier(publicKey: privateKey.publicKey)
    }

    public var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    public func sign(_ ticket: MinuteTicket) throws -> SignedTicket {
        let signature = try privateKey.signature(for: ticket.canonicalPayload)
        return SignedTicket(ticket: ticket, signature: signature.base64EncodedString())
    }
}
