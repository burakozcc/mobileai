#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""String Catalog denetimi — Xcode'un yapmadığı işler.

NEDEN VAR: Xcode `.xcstrings` dosyalarını derlemede doğrulamıyor. Aşağıdaki üç
hata sınıfı sessizce geçiyor ve yalnızca o dili kullanan kullanıcıda ortaya
çıkıyor — yani bizde asla:

  1. BİÇİM BELİRTECİ UYUŞMAZLIĞI. Kaynakta `%lld`, çeviride `%@` kalmışsa
     `String(format:)` bir tamsayıyı işaretçi sanıp okumaya çalışır ve uygulama
     O DİLDE ÇÖKER. Bu, kaçırdığımız en pahalı hata türü: test edilen dilde
     hiç görünmüyor.

  2. EKSİK DİL. Bir anahtar sekiz dilden birinde yoksa o kullanıcı Türkçe
     kaynak metni görür. Derleme yeşil, ürün bozuk.

  3. KATALOGDA OLMAYAN ANAHTAR. Kaynakta `String(localized:)` ile üretilen bir
     anahtarın karşılığı yoksa kullanıcı ham Türkçe anahtarı görür.

Üçü de KAPI (exit 1). Dördüncü bir denetim daha var — SwiftUI dizge
sabitlerinin (`Text("...")`) anahtarları — ama o UYARI seviyesinde: marka adı
ve `#Preview` örnek metinleri gibi bilinçli olarak çevrilmeyen doğru
kullanımlar üretiyor.

Kullanım:
    python3 Tools/verify-localizations.py

Bağımlılık yok, yalnız standart kütüphane. Derleme gerektirmiyor: CI'da
derlemeden ÖNCE koşuyor ki 10 dakikalık bir derlemenin sonunda değil, iki
saniyede haber versin.
"""

import io
import itertools
import json
import os
import re
import sys

LANGS = ["tr", "en", "es", "fr", "ar", "hi", "bn", "zh-Hans"]

CATALOGS = [
    ("uygulama", "AuraVoice/Resources/Localizable.xcstrings"),
    ("widget", "AuraVoiceWidget/Localizable.xcstrings"),
    ("kısayol", "AuraVoice/Resources/AppShortcuts.xcstrings"),
    ("InfoPlist", "AuraVoice/Resources/InfoPlist.xcstrings"),
]

APP_CATALOG = "AuraVoice/Resources/Localizable.xcstrings"
WIDGET_CATALOG = "AuraVoiceWidget/Localizable.xcstrings"

# App Group sınırındaki tek ortak dosya: İKİ hedefte birden derleniyor, bu
# yüzden anahtarları iki katalogda da bulunmak zorunda (`String(localized:)`
# çağıranın paketine bakıyor).
SHARED_FILE = "AuraVoice/Core/Intents/SharedLaunchContract.swift"

# `%1$@` / `%lld` / `%.1f` / `%@` ... — `%%` kaçışı ayrıca eleniyor.
SPEC = re.compile(
    r"%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(ll|l|h|hh|z|q|L)?([@dioufeEgGxXcsp%])"
)

LOCALIZED_CALL = re.compile(r'String\(localized:\s*"')

# LocalizedStringKey bekleyen yaygın konumlar (UYARI seviyesi).
LSK_CALL = re.compile(
    r'(?:Text|Label|Button|Toggle|TextField|SecureField|Section|Link|NavigationLink|Stepper|Picker)\(\s*"'
    r'|\.(?:accessibilityLabel|accessibilityValue|accessibilityHint|navigationTitle|help)\(\s*"'
)

# Bilerek çevrilmeyen, anahtarı kendisi olan doğru kullanımlar.
LSK_ALLOWED = {
    "AuraVoice",          # marka adı — anahtar bulunamayınca zaten kendisi yazılıyor
}

errors = []
warnings = []


# --------------------------------------------------------------- yardımcılar

def signature(text):
    """Argümanların SIRASINA göre tip dizisi.

    Konumsal (`%1$@`) ise konuma göre sıralanıyor; hepsi konumsuz ise metindeki
    sıra. Bir kısmı konumsal bir kısmı değilse ("KARIŞIK") — o başlı başına
    hata, çünkü davranışı platforma bağlı.
    """
    found = []
    for m in SPEC.finditer(text):
        if m.group(3) == "%":            # `%%` = literal yüzde işareti
            continue
        pos = int(m.group(1)) if m.group(1) else None
        found.append((pos, (m.group(2) or "") + m.group(3)))

    if not found:
        return ()
    if all(p is not None for p, _ in found):
        return tuple(k for _, k in sorted(found, key=lambda x: x[0]))
    if any(p is not None for p, _ in found):
        return ("KARIŞIK",)
    return tuple(k for _, k in found)


def read_json(path):
    try:
        return json.load(io.open(path, encoding="utf-8"))
    except Exception as exc:                                  # noqa: BLE001
        errors.append("%s okunamadı (geçerli JSON değil?): %s" % (path, exc))
        return None


def scan_swift_literal(text, i, escape_percent):
    r"""`i` açılış tırnağının hemen sonrası. Xcode'un üreteceği ANAHTARI döndürür.

    İnterpolasyonlar tipine göre belirtece çevriliyor.

    `escape_percent` İKİ API'nin farkını taşıyor ve bu fark kataloğun
    kendisinden okundu, tahmin değil:
      · `String(localized:)` → `String.LocalizationValue`. Literal `%` OLDUĞU
        GİBİ kalıyor; katalogdaki anahtar `%.1f dk`.
      · `Text("...")` → `LocalizedStringKey`. Literal `%` `%%` olarak
        kaçırılıyor; `Text("%\(Int(x))")` için anahtar `%%%lld`.
    Bu ayrım yapılmazsa elle biçim belirteci yazılmış her dizge yanlış alarm verir.
    """
    out, depth, start = [], 0, 0
    while i < len(text):
        c = text[i]
        if depth == 0:
            if c == "\\" and i + 1 < len(text):
                if text[i + 1] == "(":
                    depth, start, i = 1, i + 2, i + 2
                    continue
                out.append(text[i:i + 2])
                i += 2
                continue
            if c == '"':
                return "".join(out), i + 1
            out.append("%%" if (escape_percent and c == "%") else c)
            i += 1
        else:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    expr = text[start:i].strip()
                    out.append("%lld" if expr.startswith("Int(") else "%@")
                    i += 1
                    continue
            elif c == '"':                                     # iç içe dizge
                i += 1
                while i < len(text) and text[i] != '"':
                    if text[i] == "\\":
                        i += 1
                    i += 1
            i += 1
    return None, i


def specifier_variants(key):
    """Belirteç TİPİ çıkarımı kesin değil (`\\(x)` Int mi String mi bilinmiyor).

    Her `%@` yuvasını `%lld` ile de deneyerek yanlış alarmı eliyoruz. Yuva
    sayısı ve SIRASI korunduğu için bu, gerçek bir eksiği gizlemiyor.
    """
    slots = [m.start() for m in re.finditer(r"%@", key)]
    if not slots or len(slots) > 4:
        return {key}
    out = set()
    for combo in itertools.product(["%@", "%lld"], repeat=len(slots)):
        parts, cur = [], 0
        for i, pos in enumerate(slots):
            parts.append(key[cur:pos])
            parts.append(combo[i])
            cur = pos + 2
        parts.append(key[cur:])
        out.add("".join(parts))
    return out


def swift_files(base):
    for root, _dirs, files in os.walk(base):
        for f in sorted(files):
            if f.endswith(".swift"):
                yield os.path.join(root, f).replace("\\", "/")


def keys_in_file(path, pattern, escape_percent):
    src = io.open(path, encoding="utf-8").read()
    out = []
    for m in pattern.finditer(src):
        key, _end = scan_swift_literal(src, m.end(), escape_percent)
        if key:
            line = src.count("\n", 0, m.start()) + 1
            out.append((key, "%s:%d" % (path, line)))
    return out


# ------------------------------------------- 1) katalog iç tutarlılığı (KAPI)

def check_catalog_consistency():
    checked = 0
    for name, path in CATALOGS:
        if not os.path.exists(path):
            errors.append("Katalog bulunamadı: %s" % path)
            continue
        doc = read_json(path)
        if doc is None:
            continue
        if doc.get("sourceLanguage") != "tr":
            errors.append("[%s] sourceLanguage %r — 'tr' bekleniyordu"
                          % (name, doc.get("sourceLanguage")))

        for key, entry in doc.get("strings", {}).items():
            base = signature(key)
            if base == ("KARIŞIK",):
                errors.append("[%s] kaynak anahtarda karışık konumsal belirteç: %r" % (name, key))

            locs = entry.get("localizations", {})
            if not locs:
                continue                       # henüz çevrilmemiş: ayrı konu

            missing = [l for l in LANGS if l not in locs]
            if missing:
                errors.append("[%s] eksik dil (%s): %r" % (name, ",".join(missing), key[:70]))

            for lang, loc in locs.items():
                units = []
                if loc.get("stringUnit"):
                    units.append(loc["stringUnit"].get("value"))
                # Çoğul varyantları: her kategori ayrı denetleniyor.
                for _cat, var in (loc.get("variations", {}).get("plural", {}) or {}).items():
                    units.append((var.get("stringUnit") or {}).get("value"))

                for value in units:
                    if value is None:
                        continue
                    checked += 1
                    got = signature(value)
                    if got == ("KARIŞIK",):
                        errors.append("[%s][%s] karışık konumsal belirteç: %r" % (name, lang, key[:60]))
                    elif got != base:
                        errors.append(
                            "[%s][%s] BELİRTEÇ UYUŞMAZLIĞI — o dilde çökme riski\n"
                            "      anahtar: %r\n      kaynak : %s\n      çeviri : %s\n      metin  : %r"
                            % (name, lang, key[:70], base or "()", got or "()", value[:90])
                        )
    return checked


# ------------------------------- 2) String(localized:) anahtarları var mı (KAPI)

def check_source_keys():
    app_cat = set((read_json(APP_CATALOG) or {}).get("strings", {}))
    widget_cat = set((read_json(WIDGET_CATALOG) or {}).get("strings", {}))

    app_keys, widget_keys = {}, {}
    for path in swift_files("AuraVoice"):
        for key, where in keys_in_file(path, LOCALIZED_CALL, escape_percent=False):
            app_keys.setdefault(key, where)
    for path in swift_files("AuraVoiceWidget"):
        for key, where in keys_in_file(path, LOCALIZED_CALL, escape_percent=False):
            widget_keys.setdefault(key, where)
    # Ortak dosya uzantı hedefinde de derleniyor.
    for key, where in keys_in_file(SHARED_FILE, LOCALIZED_CALL, escape_percent=False):
        widget_keys.setdefault(key, where)

    total = 0
    for label, keys, cat in (("uygulama", app_keys, app_cat), ("widget", widget_keys, widget_cat)):
        for key, where in sorted(keys.items()):
            total += 1
            if key in cat or (specifier_variants(key) & cat):
                continue
            errors.append("[%s] katalogda olmayan anahtar: %r\n      %s" % (label, key, where))
    return total


# --------------------------- 3) LocalizedStringKey dizge sabitleri (UYARI)

def check_localized_string_keys():
    app_cat = set((read_json(APP_CATALOG) or {}).get("strings", {}))
    widget_cat = set((read_json(WIDGET_CATALOG) or {}).get("strings", {}))

    total = 0
    for base, cat, label in (("AuraVoice", app_cat, "uygulama"),
                             ("AuraVoiceWidget", widget_cat, "widget")):
        paths = list(swift_files(base))
        if label == "widget":
            paths.append(SHARED_FILE)
        for path in paths:
            for key, where in keys_in_file(path, LSK_CALL, escape_percent=True):
                # Çevrilecek bir harf yoksa (saf noktalama) anlamsız.
                if not re.search(r"[A-Za-zÀ-ÿĞğİıŞşÇçÖöÜü]", key):
                    continue
                total += 1
                if key in LSK_ALLOWED or key in cat or (specifier_variants(key) & cat):
                    continue
                warnings.append("[%s] katalogda olmayan dizge sabiti: %r (%s)" % (label, key, where))
    return total


# ------------------------------------------------------------------- çalıştır

def main():
    translations = check_catalog_consistency()
    source_keys = check_source_keys()
    literals = check_localized_string_keys()

    print("Denetlenen çeviri        : %d" % translations)
    print("String(localized:) anahtarı: %d" % source_keys)
    print("Dizge sabiti             : %d" % literals)

    for w in warnings:
        print("::warning::%s" % w.replace("\n", " "))

    if errors:
        print()
        for e in errors:
            print("::error::%s" % e.replace("\n", "%0A"))
        print("\nHATA: %d" % len(errors))
        return 1

    print("\nYerelleştirme denetimi temiz (%d uyarı)." % len(warnings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
