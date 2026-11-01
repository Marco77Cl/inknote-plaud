# 分阶段验收

## A. 不改写固件
- USB 与芯片识别：已通过。
- 保存出厂串口日志：已完成。
- 完整 16 MB Flash 备份：进行中；完成后记录 SHA-256，并通过设备端 MD5 比对全部 Flash。
- 出厂系统：用户操作拨轮上下、按下、BOOT 返回，观察菜单真实变化；串口辅助检查事件。
- TF：已挂载，读写完整性尚待专用测试。
- 电池/扬声器：未安装，不测试。

## B. 开发环境与官方 Demo
- ESP-IDF 5.5.2 官方 tag、官方 ESP32-S3 工具链。
- 先编译官方 01_E-Paper_Example（apps/official-epaper），不因编译成功标记屏幕通过。
- 官方 02_Mic_test 为 3 秒 RAM 采样与扬声器回放，16 kHz / 16-bit / 双通道接口；不直接等同于所需 Mono WAV。
- 官方 04_SD_Test 读 BMP；挂载设置 format_if_mount_failed=false。
- 烧录前必须有备份校验、明确写入地址/分区范围和恢复方式；不擦除 NVS、SPIFFS、eFuse 或 TF。

## C. 必要的验证适配
在官方 Demo 基础上增加诊断属于“适配版”，不可称为原版 Demo：
- TF：用独有文件名写入已知内容，关闭重开，比对大小与校验，保留验证文件。
- MIC：检查采样返回码、左右时隙数据分布、静音与讲话变化；保存短 WAV，在 Mac 上检查参数并听取。
- Wi-Fi：先扫描验证无线功能，连接网络须另有目标 SSID/用户输入凭据；不从 Mac 提取密码。
- 按键：每个物理动作与日志/画面对应，不能仅凭 GPIO 初始化判通过。
- E-Ink：用户观察全刷与局刷，无卡死；日志只确认程序执行，不替代视觉验收。

## D. InkNote 首版（前置硬件验收后）
- 16 kHz / signed PCM 16-bit little endian / mono / WAV。
- TF 逻辑目录 /recordings/，若 VFS 挂载点为 /sdcard，则程序路径 /sdcard/recordings/。
- READY → RECORDING → SAVING → COMPLETE；独立错误状态，失败不能显示 COMPLETE。
- 流式录音，屏幕刷新不得阻塞采集；完成写回 WAV 长度并关闭文件。
- 文件不覆盖已有记录；检查空间不足、写入失败、SD 拔出。
- 不以双通道交错数据写入 mono 头；根据有效采样通道验证进行选择或正确转换。
- 结束后核对 WAV 头、数据长度、时长、可听内容与屏幕文件信息。
