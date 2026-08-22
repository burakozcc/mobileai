//
//  SpeakerLabeler.swift
//  AuraVoice
//
//  Ayrıştırmayı boru hattına bağlayan ince katman. Her iki motor da bunu
//  kullanır — ses dosyası zaten cihazda olduğu için online modda da
//  konuşmacılar yerel olarak bulunur, buluta ekstra veri gitmez.
//
//  ASLA HATA FIRLATMAZ: konuşmacı etiketi bir bonus, transkript ise asıl
//  üründür. Ayrıştırma çökerse etiketsiz transkript döner — kullanıcı
//  kaydını ve dakikasını kaybetmez.
//

import Foundation

public struct SpeakerLabeler: Sendable {

    private let diarizer: any SpeakerDiarizer
    private let isEnabled: Bool

    public init(
        diarizer: any SpeakerDiarizer = SpeakerKitDiarizer(),
        isEnabled: Bool = true
    ) {
        self.diarizer = diarizer
        self.isEnabled = isEnabled
    }

    /// Segmentlere konuşmacı etiketi ekler. Başarısızlıkta girdiyi aynen döner.
    public func label(_ segments: [TranscriptSegment], audioURL: URL) async -> [TranscriptSegment] {
        guard isEnabled, !segments.isEmpty else { return segments }
        guard await diarizer.isAvailable else { return segments }

        do {
            let output = try await diarizer.diarize(audioURL: audioURL)
            guard output.speakerCount > 1 else {
                // Tek konuşmacı varsa etiket gürültüden ibaret olur.
                return segments
            }
            return SpeakerAssignment.apply(turns: output.turns, to: segments)
        } catch {
            print("[AuraVoice] Konuşmacı ayrıştırma atlandı: \(error.localizedDescription)")
            return segments
        }
    }

    /// Kullanıcı ayarını okuyan varsayılan kurulum.
    public static func makeDefault(
        expectedSpeakerCount: Int? = nil,
        defaults: UserDefaults = .standard
    ) -> SpeakerLabeler {
        // Ayar hiç yazılmamışsa varsayılan açık: model kuruluysa etiketle.
        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        return SpeakerLabeler(
            diarizer: SpeakerKitDiarizer(expectedSpeakerCount: expectedSpeakerCount),
            isEnabled: enabled
        )
    }

    public enum Keys {
        public static let enabled = "aura.diarization.enabled"
    }
}
