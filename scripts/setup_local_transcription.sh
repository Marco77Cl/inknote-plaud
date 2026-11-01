#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo=tools/whisper.cpp
if [ ! -d "$repo/.git" ]; then
  git clone --depth 1 --branch v1.8.7 https://github.com/ggml-org/whisper.cpp.git "$repo"
fi
[ "$(git -C "$repo" rev-parse HEAD)" = "48f628a84833905ee4a0658ee6d4a5c915ce1997" ] || { echo 'Unexpected Whisper source revision'; exit 1; }
tools/host-venv/bin/python -m pip install cmake
tools/host-venv/bin/cmake -S "$repo" -B "$repo/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF
tools/host-venv/bin/cmake --build "$repo/build" --config Release -j 4 --target whisper-cli
if [ ! -f "$repo/models/ggml-small.bin" ]; then bash "$repo/models/download-ggml-model.sh" small; fi
printf '%s\n' '55356645c2b361a969dfd0ef2c5a50d530afd8d5  tools/whisper.cpp/models/ggml-small.bin' | shasum -a 1 -c -
bash apps/inknote-studio/build.sh
