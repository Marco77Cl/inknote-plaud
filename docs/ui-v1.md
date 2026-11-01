# InkNote 中文竖屏界面 v1

2026-10-16。用户选择竖屏中文极简，暂缓长时稳定性测试。

- 480×800逻辑画布，270度映射到800×480控制器缓冲。
- 准备记录、正在录音、正在保存、已保存、需要处理五个界面。
- 显示实际PCM数据对应时长、文件名、音频数据大小；保留拨轮开始/停止与BOOT停止。
- 状态切换完整刷新约3.06秒；录音期间直接采样最新进度，局部刷新时长与文件信息，每秒更新，实测627–628ms。

## 验证
- ESP-IDF编译通过，应用657664字节。
- 主机直接编译固件ui_render.c，AddressSanitizer/UBSan运行五个状态无报错，输出design/firmware-ui-*.png。
- 实际WAV头生成回归通过。
- 已仅写入0x10000应用分区，esptool Hash of data verified。
- 启动日志确认STATE=READY、DISPLAY=READY，TF和音频初始化成功。
- 固件SHA256：68de57256eecf3c5aec6fe8c69ceb41488f115402e549f1aa444c25a9ae434d7。
- 用户确认新版效果“非常好”。设备短录音15.104秒，RESULT ok=1，483328音频字节，无采集溢出或写入错误报告，DISPLAY完成RECORDING/SAVING/COMPLETE。此次未取卡核验WAV实文件，长时稳定性与异常恢复未验收。
- 设备证据：logs/inknote-ui-timer-device.log；固件留档：releases/ui-v1/inknote.bin。

生成资源：scripts/build_ui_assets.py。固件绘制：apps/inknote/main/ui_render.c。

## v1.1 首次计时修正

- 问题：进入录音页面的完整刷新约3秒，首次可见进度跳至3秒。
- 修正：READY/COMPLETE保留控制器底图，开始录音使用全画幅局部波形刷新；录音采样不延后、不修改真实计时。保存过程仍完整刷新清理残影。待机不再进入屏幕深睡，功耗影响尚未测量。
- 实测两次开始刷新均642ms，日志均显示0、1、2秒；用户确认OK。
- 两段录音15.040秒、6.016秒，RESULT ok=1，未报告采集溢出或写入错误。
- 证据logs/inknote-quick-start-device.log；固件releases/ui-v1.1/inknote.bin。
- SHA256 bf69b34ea8ef4621c59c86b6b7ffc5cdea3d579dd141dff9bc021c7039a00d39。

## v1.2 跨页面闪烁修正（2026-10-17用户确认）

- 用户随后发现v1.1在录音时反复显现“准备记录/已保存”。日志状态无往返，先前OK不构成此问题已消除的证据。
- 尝试局部更新后同步0x26参考平面，用户反馈仍闪烁；该补丁已撤销。
- 当前使用EPD_Init_Fast + EPD_Display_Fast_Base建立录音页底图，随后保留计时区域局部刷新。
- 代价：进入录音页实测2642ms，前几秒显示延迟尚未彻底解决；不延后真实音频采集。
- 14.976秒及5.952秒短录音日志RESULT ok=1，均完成保存；屏幕闪烁是否消除等待用户确认。
- 证据：logs/inknote-stable-base-device.log。固件：releases/ui-v1.2/inknote.bin。
- SHA256：9113dce26c45b206e98c2afe671eb4164f3d0077c06e4e2986b618ab6487c95f。
- epaper_port从官方组件链接改为项目本地副本，最终代码与官方一致，未修改vendor。

### 2026-10-17 实物复测
- 用户确认“状态稳定，只有计时更新”，本次确认覆盖重复录音的状态文字闪烁问题。
- 证据 logs/inknote-stable-base-retest-20261017.log，两次RESULT ok=1，14.912秒及6.016秒，均DISPLAY=COMPLETE。
- 第一段报告1个削波样本（peak32768），第二段0个；本次为界面验收，不据此认定音频质量已全面验证。
- 进入录音页2642ms，后续局部刷新627–628ms；最初几秒显示延迟仍存在。未变更固件。
