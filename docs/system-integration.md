# InkNote 原厂系统集成

2026-10-17。工程 `apps/inknote-system` 基于已下载的 Waveshare 官方 08 完整系统，独立版 `apps/inknote` 与备份固件保留。

## 操作

原厂主菜单 → 音频 → InkNote 会议录音。

- 拨轮单击：开始录音；录音中再单击：停止并保存。
- BOOT / 拨轮双击：录音中先停止并保存；READY、COMPLETE、ERROR 时返回音频菜单。
- 保存中等待写入和显示队列完成，避免未完成文件被当作已保存。
- 在音频菜单按 BOOT / 双击拨轮返回原厂主菜单。
- WAV 继续保存在 TF 卡 `/recordings/`，16 kHz、16-bit、mono、PCM，独占文件创建与 `.part` 完成后改名流程保留。

## 实现与边界

- 新增音频菜单首项，原播放、原录音、文件管理、返回主菜单全部保留。
- 复用原厂已初始化的 SD、音频与按键；InkNote 使用独立采集/写入任务，页面同步持有显示，退出后父菜单完整重画。
- 退出恢复 RX 双声道配置和原12dB输入增益；再次进入设置 InkNote 30dB输入增益和mono LEFT。
- InkNote 持有音频会话互斥锁，后台闹钟响铃等待退出页面，避免争抢音频和按键。
- 跨页面使用完整波形建立底图，计时区局部刷新，保留此前用户确认的稳定策略。进入录音页仍有约2.6秒显示延迟。
- TF 及SPIFFS挂载失败均不自动格式化。仅烧写0x10000应用，NVS、引导程序、分区表、原SPIFFS内容保留。
- 未添加AI、联网同步或新的播放界面。原厂其他功能保留代码不等于已逐项完成实机回归。

## 检查

- ESP-IDF 5.5.2 编译成功，应用13,859,696字节，15MB应用分区可容纳。
- 新分区表二进制与当前独立版逐字节一致。
- 直接编译集成版WAV头生成代码，Python wave验证mono PCM16/16000Hz通过。
- 原厂接口资源释放、保存后退出路径已代码检查。
- esptool应用写入校验成功；原厂完整系统启动、TF挂载、Wi-Fi自动重连及NTP写RTC日志正常。
- 菜单进入/录音/退出/再次进入、返回后播放原厂音频：待用户操作验收。
- 固件SHA256：f075a8bc51a33d34d4d1caea622bdd489e342a16fe6b7a6664d2bdaf1f0bb09f。

固件留档：`releases/system-v0.1/inknote_system.bin`。刷写及启动日志：`logs/inknote-system-flash.log`、`logs/inknote-system-device.log`。

## v0.1.1 入口立即返回修复

用户确认二级菜单可见但点击不能进入，旧日志多次PAGE_ENTER/PAGE_EXIT同一时间戳，无READY。入口已触发，返回发生在显示/队列/录音缓冲分配阶段。

FreeRTOS动态StreamBuffer通过pvPortMalloc限定内部RAM，128KB数据缓冲在完整原厂系统下容易无法分配。改用PSRAM数据区（128KB+1字节）与内部静态控制块创建StreamBuffer，并增加内存诊断与可返回的错误界面，避免静默退出。

编译、WAV头回归、应用刷写hash校验通过；本次刷入13,860,352字节。固件releases/system-v0.1.1/inknote_system.bin，SHA256 68878daad67103501fb4ee226f3edee2a57c268b3075389787246e1b58a4195c。日志logs/inknote-system-memory-device.log。用户确认可以进入。日志PAGE_ENTER显示内部最大连续块45056字节（44KB）、PSRAM空闲8257732字节；PAGE_RESOURCES_OK后进入READY，根因与128KB内部缓冲申请不匹配。

用户完成8.064秒录音rec_98b88f3f.wav，258048音频字节，RESULT ok=1、clipped=0，DISPLAY=COMPLETE后PAGE_EXIT确认返回。返回后原厂播放及再次进入尚待确认。

## v0.2 主菜单入口与关机留屏（用户已确认）

- 主菜单第二行左侧“日历”替换为InkNote与声纹图标，直接打开录音页，退出后完整刷新回主菜单。音频子菜单入口仍保留。
- 原日历日志显示逐日联网获取整月农历数据，前台等待导致用户感觉卡住。新入口不再调用日历获取。旧日历专用开机模式2迁移为普通主菜单模式0。
- 页面底部改为“BOOT 返回上级菜单”，适配主菜单/音频菜单两种来源。
- 正常软件关机统一在axp_pwr_off的回调中绘制“已关机／按电源键重新启动”，完成全屏刷新后清理音频并关闭PMU。屏幕初始化前的提前断电、强制硬件断电无法保证绘制。
- 编译通过，固件releases/system-v0.2/inknote_system.bin。首次刷写因USB串口不存在而未开始；用户重新插拔USB后重试成功，仅写应用分区，13858560字节，Hash of data verified。启动日志正常，等待用户确认主菜单进出和关机留屏。
- 固件SHA256：0feaae046a484c38791cca39d5ee73a0d7960b9992a8e838d3db7662267bd800。日志logs/inknote-home-shutdown-flash-retry.log与logs/inknote-home-shutdown-device.log。

### v0.2 实物验收
用户对主菜单InkNote入口、进入准备记录、BOOT返回主菜单、主菜单BOOT关机及专用关机留屏确认“没问题”。本次验收覆盖上述交互；不代表全系统功能、续航或异常断电测试完成。
