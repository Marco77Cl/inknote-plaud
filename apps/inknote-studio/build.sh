#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/'InkNote Studio.app'/Contents/MacOS build/'InkNote Studio.app'/Contents/Resources
swiftc -swift-version 5 -parse-as-library -O -module-cache-path /tmp/inknote-swift-cache InkNoteStudio.swift Transcription.swift MeetingFeatures.swift BookImport.swift BookLibrary.swift USBTransport.swift -o 'build/InkNote Studio.app/Contents/MacOS/InkNoteStudio' -framework SwiftUI -framework AppKit -framework AVFoundation -framework CryptoKit
cat > 'build/InkNote Studio.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.inknote.studio</string><key>CFBundleName</key><string>InkNote Studio</string><key>CFBundleExecutable</key><string>InkNoteStudio</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>6</string><key>CFBundleShortVersionString</key><string>0.4.1</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/><key>NSLocalNetworkUsageDescription</key><string>发现并连接局域网中的InkNote录音设备，下载您选择的录音。</string><key>NSBonjourServices</key><array><string>_inknote._tcp</string></array><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
cp assets/AppIcon.icns 'build/InkNote Studio.app/Contents/Resources/AppIcon.icns'
if [ "${INKNOTE_EXECUTABLE_ONLY:-0}" = 1 ]; then
  codesign --force --sign - 'build/InkNote Studio.app'
  exit 0
fi
speech='build/InkNote Studio.app/Contents/Resources/Speech'
mkdir -p "$speech"
cp ../../tools/whisper.cpp/build/bin/whisper-cli "$speech/whisper-cli"
cp ../../tools/whisper.cpp/models/ggml-small.bin "$speech/ggml-small.bin"
cp ../../tools/whisper.cpp/LICENSE "$speech/whisper-LICENSE.txt"
codesign --force --sign - "$speech/whisper-cli"
meeting='build/InkNote Studio.app/Contents/Resources/Meeting'
sherpa='../../tools/host-venv/lib/python3.9/site-packages/sherpa_onnx'
mkdir -p "$meeting"
clang++ -std=c++17 -O2 native/speaker_cli.cc -I "$sherpa/include" -L "$sherpa/lib" -lsherpa-onnx-cxx-api -lsherpa-onnx-c-api -Wl,-rpath,@executable_path -o "$meeting/speaker-cli"
cp "$sherpa/lib/libsherpa-onnx-cxx-api.dylib" "$sherpa/lib/libsherpa-onnx-c-api.dylib" "$sherpa/lib/libonnxruntime.dylib" "$meeting/"
cp ../../tools/llama.cpp/build/bin/llama-completion "$meeting/"
cp ../../tools/meeting-models/qwen2.5-7b-instruct-q4_k_m.gguf "$meeting/summary.gguf"
cp ../../tools/meeting-models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx "$meeting/segmentation.onnx"
cp ../../tools/meeting-models/embedding.onnx "$meeting/embedding.onnx"
cp native/summary.gbnf "$meeting/"
cp ../../tools/llama.cpp/LICENSE "$meeting/llama-LICENSE.txt"
cp "$sherpa/../sherpa_onnx-1.13.8.dist-info/licenses/LICENSE" "$meeting/sherpa-LICENSE.txt"
if [ -f ../../tools/meeting-models/Qwen-LICENSE.txt ]; then cp ../../tools/meeting-models/Qwen-LICENSE.txt "$meeting/Qwen-LICENSE.txt"; fi
for binary in "$meeting"/*.dylib "$meeting/speaker-cli" "$meeting/llama-completion"; do codesign --force --sign - "$binary"; done
codesign --force --sign - 'build/InkNote Studio.app'  
