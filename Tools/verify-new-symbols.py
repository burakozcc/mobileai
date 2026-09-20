#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bir değişikliğin EKLEDİĞİ `.üye` erişimlerinin bildirimi var mı?

NEDEN VAR: Bu depoda derleyici yalnızca CI'da çalışıyor (geliştirme Windows'ta).
"Kullanılan ama bildirilmeyen sembol" hatası tek bir dosyada bile olsa HEDEFİN
TAMAMININ derlenmesini engelliyor — yani CI'da tek test koşmuyor ve hata mesajı
çoğu zaman değişikliğin asıl konusuyla ilgisiz bir satırı gösteriyor.

Bu betik tam olarak o sınıfı arıyor: diff'in eklediği satırlardaki her
`<ifade>.<üye>` erişimi için depoda bir bildirim (var/let/func/case/parametre
etiketi) var mı diye bakıyor.

NEDEN KAPI DEĞİL, UYARI: kapsam diff olduğu için gürültü düşük (tipik olarak
bir avuç ad), ama sıfır değil — değişiklik yeni bir SwiftUI değiştiricisi ya da
Foundation API'si kullanıyorsa o da "bildirimsiz" görünür. Aşağıdaki liste
bilinen Apple adlarını eliyor, ama tam olamaz ve zamanla çürür. Her yeni Apple
çağrısında kırmızıya dönen bir kapı, hiç kapı olmamasından KÖTÜDÜR; o yüzden
çıktı uyarı, çıkış kodu 0.

SINIRI: sembolün DEPODA bir yerde bildirilmiş olmasına bakıyor, DOĞRU TİPTE
bildirilmiş olmasına değil. `viewModel.foo`, `foo` alakasız bir struct'ta
bildirilmişse buradan geçer. Tip-farkında denetim derleyicinin işi.

Kullanım:
    python3 Tools/verify-new-symbols.py                 # çalışma ağacındaki değişiklikler
    python3 Tools/verify-new-symbols.py --base origin/main
"""

import argparse
import io
import os
import re
import subprocess
import sys

DECL = re.compile(
    r"\b(?:var|let|func|case|enum|struct|class|protocol|typealias|actor)\s+([A-Za-z_]\w*)"
)
# Parametre etiketleri ve `x: Tip` biçimli bildirimler de birer bildirimdir.
LABEL_DECL = re.compile(r"\b([a-z_]\w*)\s*:\s*[A-Z@\[(]")
ENUM_CASE = re.compile(r"^\s*case\s+([a-z_]\w*)", re.M)

USE = re.compile(r"\.([a-z_]\w*)")
SWIFT_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')

SOURCE_DIRS = ("AuraVoice", "AuraVoiceWidget", "AuraVoiceTests")

# Apple çerçevelerinden gelen, bu depoda hiç bildirilmeyecek yaygın adlar.
# Eksiksiz DEĞİL ve olması da beklenmiyor — bkz. dosya başındaki gerekçe.
KNOWN = set("""
accessibilityElement accessibilityHidden accessibilityHint accessibilityLabel
accessibilityValue allCases allSatisfy append appendingPathComponent ascii async
background badge base64EncodedString bold bottom buttonStyle
caption caption2 compactMap components contains containerBackground
contentTransition count current custom
data date dateStyle decode decodeIfPresent default description
disabled down dropFirst dropLast
encode endIndex enumerated
fill filter first firstIndex fixedSize flatMap folding font
foregroundStyle frame fractionCompleted
hasPrefix hasSuffix headline hidden horizontal
ignoresSafeArea init inline isEmpty isLetter isNumber
joined keys
last lineLimit localizedDescription lowercased
main map max medium milliseconds min monospacedDigit
multilineTextAlignment
never none now
offset onAppear onChange onDisappear opacity overlay
padding plain prefix
rawValue reduce regular removeAll removeFirst removeLast
replacingOccurrences resume reversed rounded rotationEffect
seconds semibold shadow shared sheet sleep some sorted split
standard startIndex stroke strokeBorder suffix
tag task timeIntervalSince1970 top tracking trimmingCharacters
uppercased utf8 value values vertical
write
""".split())


def run(args):
    proc = subprocess.run(args, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    return proc.stdout if proc.returncode == 0 else None


def collect_declarations():
    declared = set()
    for base in SOURCE_DIRS:
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base):
            for f in files:
                if not f.endswith(".swift"):
                    continue
                src = io.open(os.path.join(root, f), encoding="utf-8").read()
                declared.update(DECL.findall(src))
                declared.update(LABEL_DECL.findall(src))
                declared.update(ENUM_CASE.findall(src))
    return declared


def added_lines(base_ref):
    """Diff'in eklediği satırlar: (dosya, satır metni)."""
    args = ["git", "diff", "-U0"]
    if base_ref:
        args.append(base_ref)
    args += ["--", "*.swift"]

    diff = run(args)
    if diff is None:
        return None

    out, current = [], None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif line.startswith("+") and not line.startswith("+++"):
            out.append((current, line[1:]))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=None,
                        help="Karşılaştırılacak git referansı (örn. origin/main). "
                             "Verilmezse çalışma ağacındaki değişiklikler.")
    args = parser.parse_args()

    lines = added_lines(args.base)
    if lines is None:
        print("git diff çalıştırılamadı (referans yok?) — denetim atlandı.")
        return 0
    if not lines:
        print("Eklenen Swift satırı yok — denetim atlandı.")
        return 0

    declared = collect_declarations()

    suspects = {}
    for path, body in lines:
        stripped = body.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        body = SWIFT_STRING.sub('""', body)
        for name in USE.findall(body):
            if name in KNOWN or name in declared:
                continue
            suspects.setdefault(name, set()).add(path)

    print("İncelenen eklenen satır: %d" % len(lines))

    if not suspects:
        print("Bildirimi bulunamayan sembol: yok.")
        return 0

    print("Bildirimi bulunamayan %d ad (çoğu Apple API'si olabilir — göz at):"
          % len(suspects))
    for name in sorted(suspects):
        where = ", ".join(sorted(suspects[name]))
        print("::warning::.%s — bildirimi bulunamadı (%s)" % (name, where))
    return 0


if __name__ == "__main__":
    sys.exit(main())
