# InkNote

## USB 直连与轻阅读（2026-10-23）

新增 [USB 数据线传输](docs/usb-transfer.md)，支持书籍导入与录音下载。

EPUB/TXT 导入、设备书架与章节目录、字号/书签/进度保存，Mac 与设备端已更新。支持范围、使用步骤和实机验收边界见 [轻阅读说明](docs/light-reading.md)。

## Mac 本地转写与会议纪要（2026-10-18）

InkNote Studio 已集成离线 Whisper：本地录音库、中文/英语/自动识别、文字编辑保存、TXT/SRT 导出。已完成真实设备录音的原生应用流程验收。

- [说话人区分与会议纪要](docs/meeting-features.md)
- [使用与验收记录](docs/local-transcription.md)
- [Wi-Fi 传输说明](docs/wifi-transfer.md)
- 应用：`apps/inknote-studio/build/InkNote Studio.app`

以下为早期硬件 bring-up 记录，当前系统集成进度参见 [系统集成](docs/system-integration.md)。

Waveshare ESP32-S3-ePaper-3.97 上的会议记录设备。已实现并实机运行 InkNote 首版：READY → RECORDING → SAVING → COMPLETE，16 kHz / 16-bit / Mono PCM WAV 保存到 TF 卡 /recordings/。7段实录文件通过结构检查；主观试听、长时稳定性和异常恢复仍待验证。

- [当前硬件状态](docs/bringup-status.md)
- 官方示例：`vendor/waveshare/ESP-IDF/`（下载依赖，不纳入本仓库）
- 开发工具：`tools/`（本地隔离安装）
- 出厂备份：`backups/`（不纳入版本控制，不上传）
- 检测日志：`logs/`
- bash 环境入口：`. scripts/env.sh`

验收按硬件检测 → 官方 Demo → 录音固件顺序进行。编译通过不等于设备功能通过；未接电池、扬声器的功能标为未测试。

- [录音实文件验收](docs/wav-validation-2026-10-16.md)
- InkNote源代码：`apps/inknote/`。中键开始/停止，BOOT停止；屏幕刷新约3秒。
