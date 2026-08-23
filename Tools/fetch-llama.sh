#!/usr/bin/env bash
#
# Tools/fetch-llama.sh
#
# llama.cpp xcframework'unu indirir ve Vendor/ altina yerlestirir.
#
# NEDEN HAZIR ARTIFACT'I OLDUGU GIBI KULLANMIYORUZ: llama.cpp'nin GUNCEL
# release'lerinde iOS SIMULATOR DILIMI YOK (PR #27252, 2026-08-17 -- release
# is akisi artik yalnizca "macos ios-device" deriyor). AuraVoiceTests
# simulatorde kostugu ve uygulamanin tamamini linkledigi icin guncel artifact
# ile derleme "no library for this platform" ile patlar.
#
# Bu yuzden PR oncesi son surume (b10456) pinlendik; o zip ios-arm64 VE
# ios-arm64_x86_64-simulator dilimlerini iceriyor. Dogrulandi: zip'in merkezi
# dizini okunarak.
#
# Xcode DISINDA calisir (build phase degil), boylece
# ENABLE_USER_SCRIPT_SANDBOXING: YES ayarina dokunmuyoruz.
#
set -euo pipefail

TAG="${LLAMA_TAG:-b10456}"
EXPECTED_BYTES=286349259
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-xcframework.zip"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor"
FRAMEWORK="$DEST/llama.xcframework"

if [ -d "$FRAMEWORK" ] && [ -z "${LLAMA_FORCE:-}" ]; then
  echo "llama.xcframework zaten var, atlanıyor (yeniden indirmek icin LLAMA_FORCE=1)."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Indiriliyor: $URL"
curl -fL --retry 3 -o "$WORK/llama.zip" "$URL"

ACTUAL_BYTES=$(wc -c < "$WORK/llama.zip" | tr -d ' ')
if [ "$ACTUAL_BYTES" != "$EXPECTED_BYTES" ]; then
  echo "HATA: beklenen $EXPECTED_BYTES bayt, gelen $ACTUAL_BYTES" >&2
  exit 1
fi

# Butunluk pini: ilk kosuda CI loguna yazilir, sonra buraya sabitlenir.
echo "sha256: $(shasum -a 256 "$WORK/llama.zip" | cut -d' ' -f1)"
if [ -n "${LLAMA_SHA256:-}" ]; then
  echo "${LLAMA_SHA256}  $WORK/llama.zip" | shasum -a 256 -c - >/dev/null
  echo "sha256 dogrulandi."
fi

unzip -q "$WORK/llama.zip" -d "$WORK/x"
SRC="$WORK/x/build-apple/llama.xcframework"
[ -d "$SRC" ] || { echo "HATA: zip icinde beklenen yol yok: build-apple/llama.xcframework" >&2; exit 1; }

# Yalnizca iOS dilimleri kalsin. tvOS/xrOS/macOS ~200 MB ve uygulamaya hic
# girmiyor; Info.plist'ten de dusurulmeli, aksi halde Xcode'un
# "Process XCFramework" adimi eksik dizin icin patlar.
python3 - "$SRC" <<'PYEOF'
import os, plistlib, shutil, sys

root = sys.argv[1]
keep = {"ios-arm64", "ios-arm64_x86_64-simulator"}
plist_path = os.path.join(root, "Info.plist")

with open(plist_path, "rb") as f:
    plist = plistlib.load(f)

libraries = plist.get("AvailableLibraries", [])
kept = [lib for lib in libraries if lib.get("LibraryIdentifier") in keep]

missing = keep - {lib.get("LibraryIdentifier") for lib in kept}
if missing:
    raise SystemExit(f"HATA: xcframework'te eksik dilim(ler): {sorted(missing)}")

for lib in kept:
    # dSYM'ler dilim basina ~75 MB ve uygulamaya girmiyor.
    lib.pop("DebugSymbolsPath", None)

plist["AvailableLibraries"] = kept
with open(plist_path, "wb") as f:
    plistlib.dump(plist, f)

for entry in os.listdir(root):
    path = os.path.join(root, entry)
    if os.path.isdir(path) and entry not in keep:
        shutil.rmtree(path)
    elif os.path.isdir(path):
        dsyms = os.path.join(path, "dSYMs")
        if os.path.isdir(dsyms):
            shutil.rmtree(dsyms)

print("korunan dilimler:", sorted(keep))
PYEOF

mkdir -p "$DEST"
rm -rf "$FRAMEWORK"
cp -R "$SRC" "$FRAMEWORK"

echo "--- sonuc ---"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$FRAMEWORK/Info.plist" | grep LibraryIdentifier
du -sh "$FRAMEWORK"
