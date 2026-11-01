# InkNote 硬件 bring-up 记录

## 当前界面验收
- system-v0.2：主菜单日历已替换为InkNote直达入口，退出返回主菜单；正常软件关机显示独立关机留屏。用户确认上述操作均正常。
- 详见system-integration.md，固件留档releases/system-v0.2/inknote_system.bin。

## 原厂集成版最新进度
- 原厂主菜单→音频→InkNote会议录音入口可用。修复动态StreamBuffer受内部RAM限制导致静默返回：128KB数据区明确分配至PSRAM。
- 用户确认进入成功，日志证实8.064秒录音保存成功并PAGE_EXIT返回。集成工程apps/inknote-system，详见system-integration.md。

## 2026-10-17 界面复测
- v1.2完整快速波形建立录音底图，用户确认状态稳定、只有计时更新。两次短录音日志均保存成功。
- 进入录音页约2.64秒，局部计时刷新约0.63秒；首次显示延迟仍保留。详见ui-v1.md。

## 最新状态（2026-10-16，以下历史记录保留）
- 中文竖屏极简界面已烧录，录音计时逐秒局部刷新（627–628ms），用户确认效果。15.104秒短录音日志确认保存成功；详见ui-v1.md。
- 用户确认电池独立供电可正常操作。
- InkNote应用已烧录；修复ALDO3屏幕供电遗漏后用户确认显示，完成录音并显示COMPLETE。
- 应用保留原引导、分区表、NVS和SPIFFS。原出厂应用已被InkNote替换，可由backups恢复。
- 7个InkNote WAV实文件全部通过16kHz/16bit/mono PCM、数据长度和复制哈希检查，无.part残留，无数字削波。
- 30dB输入增益下两段长录音RMS约-30.0/-26.6dBFS，原出厂样本约-55.6dBFS；不是控制变量对照实验。用户试听确认声音明显改善。
- 详见 wav-validation-2026-10-16.md。基础首版流程已跑通，长时录音、异常恢复和续航未验收。


日期：2026-10-16（Asia/Shanghai）

## 约束
- Waveshare ESP32-S3-ePaper-3.97，USB 供电。
- 初始未接电池/扬声器；用户随后确认两者均已接入。电池识别和扬声器回放待验收。
- 用户确认 128 GB FAT32 TF 卡已插入，屏幕显示系统界面。
- 保留出厂固件；先备份，不烧 eFuse，不进行整片擦除，不自动格式化 TF 卡。
- AI、3D 外壳不在当前阶段范围。

## 已验证
- USB VID:PID 303a:1001，串口 /dev/cu.usbmodem1101。
- esptool 确认 ESP32-S3 rev v0.2、8 MB PSRAM；安全启动/Flash 加密均关闭。
- 出厂日志：16 MB Flash；PSRAM memory test OK。
- 出厂应用 ESP32-S3_ePaper-3.97 v1，ESP-IDF v5.4.1，构建时间 2026-01-22。
- TF 挂载成功 /sdcard，SN128，121942 MB，4-bit，40 MHz。尚未验证写入或文件完整性。
- ES8311、I2S 初始化成功，16 kHz / 16-bit / 双通道总线配置。尚未验证 MIC 采样内容。
- 用户确认屏幕有系统界面，尚未确认实际刷新、按键和拨轮响应。

## 待查
- 日志包含 I2C NACK，来源待定位。官方 XPowersAXP2101.tpp 的 getBatteryPercent() 在未检测到电池时返回 -1，与当前无电池一致。
- 官方 main.cc 中 Restarting now 仅为日志，随后永久等待，不能据此认定发生重启。
- Wi-Fi 当前关闭，尚未验证扫描/连接。
- 完整 Flash 备份已完成，16777216 字节；esptool verify_flash 全片 digest matched。SHA-256：34fac2c6ca24bc0f90600e245ee6edfd0b165de90ba92529e6ce0fca1d55bf07。未改写固件。
- ESP-IDF 5.5.2、工具链、Python依赖安装完成；全部 Git 子模块版本一致。官方显示 Demo 编译成功，生成 apps/official-epaper/build/1.bin，大小0xabe580；尚未烧录。

## 官方来源
- https://docs.waveshare.com/ESP32-S3-ePaper-3.97
- https://docs.waveshare.com/ESP32-S3-ePaper-3.97/ESP-IDF
- https://github.com/waveshareteam/ESP32-S3-ePaper-3.97
- 官方示例 commit: 9b12d40731a80213b927ee8a421cae4082952819

## 后续门槛
1. 备份校验、环境与官方 Demo 编译通过。
2. 优先现有出厂系统完成可做的硬件验证；必要的测试固件先说明改写范围。
3. MIC、TF 读写、E-Ink、按键/拨轮、Wi-Fi 验证后，再实现 InkNote 录音程序。
4. InkNote：16 kHz、16-bit、Mono PCM WAV，卡上 /recordings/，READY → RECORDING → SAVING → COMPLETE。

## 出厂系统交互测试
- 日志确认录音开始、暂停、继续、停止，保存到 /sdcard/music/record_00000101_002252.wav，日志时长21.4秒。
- 用户确认停止后返回上一级界面。已证明实际界面交互；尚未核验 WAV 文件和声音内容。
- RTC 日期未正确设置（文件名为00000101），InkNote 应避免仅依赖RTC防止文件名重复。
- 用户连接电池/扬声器后，Mac暂未发现USB串口，待重连。

## 当前恢复检查
- 用户报告拨轮无响应。Mac 的 IOUSB 与串口列表均未发现 ESP32，原因尚不明；墨水屏保留画面不证明设备仍在运行。
- 已请用户重新连接 USB、短按拨轮唤醒，必要时按 PWR 1–2秒开机，等用户回报。
- 录音回放、WAV实际文件检查、电池识别、Wi-Fi仍待验证；尚未开始 InkNote 固件实现。

## 恢复与音频验收更新
- 重新插USB后恢复操作，串口重新出现。未烧录、未擦除。
- 用户确认能清楚听出刚才录音中的讲话，但声音偏小：MIC→TF写入→重启后TF读取→扬声器基本链路通过，音量/电平质量待改进。
- 重连日志 BAT_Power=100%，电池已识别；不代表容量精度、充电、独立供电和续航已验证。
- 官方播放音量默认90，上拨+音量、下拨-音量，最大100。正在请用户比较。

## Wi-Fi与音量
- AP 启动成功：SSID -A451，DHCP 192.168.4.1，Web配网服务启动。STA连接仍待验证，已请用户用手机配网。
- 用户确认播放音量100%仍偏小，不能视为音质验收通过。官方录音输入增益配置为 EXAMPLE_MIC_GAIN(4)*3 = 12 dB，需根据 WAV 峰值/RMS 再调整。

## 网络与编译验收
- Wi-Fi STA 连接 Eiswein 成功，DHCP分配192.168.1.6；配网重启后自动重连成功（logs/factory-wifi-test.log）。
- 官方 MIC Demo 编译成功（apps/official-mic/build/1.bin），未烧录。
- 电池独立供电和 WAV实际文件检查等待用户物理操作。
