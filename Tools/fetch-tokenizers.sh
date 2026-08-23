#!/usr/bin/env bash
#
# Tools/fetch-tokenizers.sh
#
# Whisper tokenizer dosyalarini indirir. Dosyalar DEPODA tutuluyor (5,53 MB);
# bu betik yalnizca kaynagi belgeliyor ve yeni varyant eklendiginde tekrar
# kosuluyor.
#
# NEDEN GOMULU: WhisperKit'in `download: false` bayragi YALNIZCA Core ML
# agirliklarini kapsiyor; tokenizer yukleme aninda ayri bir yoldan Hugging
# Face'ten cekiliyor ve ucak modunda patliyor.
#
# tokenizer.json + tokenizer_config.json tiny/base/small/medium/large-v2
# arasinda BIREBIR AYNI (ayni git blob), yalnizca large-v3 ailesi farkli
# (vocab 51866). Bu yuzden 51865'lik set duz koke, large-v3'unki adlandirilmis
# klasore konuyor.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/AuraVoice/Resources/Tokenizers"
mkdir -p "$ROOT" "$ROOT/models/openai/whisper-large-v3"

for f in tokenizer.json tokenizer_config.json config.json; do
  curl -fL --retry 3 -o "$ROOT/$f"     "https://huggingface.co/openai/whisper-base/resolve/main/$f"
  curl -fL --retry 3 -o "$ROOT/models/openai/whisper-large-v3/$f"     "https://huggingface.co/openai/whisper-large-v3/resolve/main/$f"
done

# Git-LFS isaretcisi / yarim indirme korumasi. Beklenen tam baytlar:
#   duz kok        : tokenizer.json 2480466  tokenizer_config.json 282683  config.json 1983
#   large-v3       : tokenizer.json 2480617  tokenizer_config.json 282843  config.json 1272
find "$ROOT" -name '*.json' -exec sh -c 'printf "%s	%s
" "$(wc -c < "$1" | tr -d " ")" "$1"' _ {} \;
