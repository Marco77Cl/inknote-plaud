#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
models=tools/meeting-models
mkdir -p "$models"
tools/host-venv/bin/python -m pip install 'sherpa-onnx==1.13.8' cmake
if [ ! -d tools/llama.cpp/.git ]; then git clone https://github.com/ggml-org/llama.cpp.git tools/llama.cpp; git -C tools/llama.cpp checkout 797de63b2fa7396dcc8caca76834c699ac84e1c3; fi
[ "$(git -C tools/llama.cpp rev-parse HEAD)" = 797de63b2fa7396dcc8caca76834c699ac84e1c3 ] || { echo 'Unexpected llama.cpp revision'; exit 1; }
tools/host-venv/bin/cmake -S tools/llama.cpp -B tools/llama.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DLLAMA_BUILD_TESTS=OFF
tools/host-venv/bin/cmake --build tools/llama.cpp/build -j 4 --target llama-completion llama-gguf-split
for part in 1 2; do
  file="qwen2.5-7b-instruct-q4_k_m-0000${part}-of-00002.gguf"
  curl -fL -C - --retry 3 --retry-all-errors "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/bb5d59e06d9551d752d08b292a50eb208b07ab1f/$file" -o "$models/$file"
done
printf '%s\n' 'dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db  tools/meeting-models/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf' '539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a  tools/meeting-models/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf' | shasum -a 256 -c -
if [ ! -f "$models/qwen2.5-7b-instruct-q4_k_m.gguf" ]; then tools/llama.cpp/build/bin/llama-gguf-split --merge "$models/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf" "$models/qwen2.5-7b-instruct-q4_k_m.gguf"; fi
if [ ! -f "$models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" ]; then
 curl -fL --retry 3 https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 -o "$models/segmentation.tar.bz2"
 tar -xjf "$models/segmentation.tar.bz2" -C "$models"
fi
if [ ! -f "$models/embedding.onnx" ]; then curl -fL --retry 3 https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx -o "$models/embedding.onnx"; fi
bash scripts/setup_local_transcription.sh
