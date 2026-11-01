# InkNote 轻阅读 v0.4

更新：2026-10-23。

v0.4.1 新增 [USB 数据线直连](usb-transfer.md)，同时修复关闭 Wi-Fi 时同步入口无法启动的问题。

## 已实现

- Mac InkNote Studio 新增「阅读 · 书籍与笔记」。支持无 DRM、流式排版 EPUB；TXT 支持 UTF-8、带 BOM 的 UTF-16；笔记另支持 Markdown 原文。
- EPUB 按 OPF spine 阅读顺序提取章节和中文正文，目录按 UTF-8 字节位置定位。原文件保存在 Mac 本地书库。
- 设备原「阅读」入口现在打开「轻阅读」，包含书籍、笔记、原有 TXT 文件、连接 Mac / 同步内容。
- 书架最近阅读优先；选择书籍后继续阅读、从头阅读或进入章节目录。
- 阅读时上下拨轮翻页，单击拨轮打开字号/书签菜单，双击 BOOT 或拨轮返回。进度按正文位置保存，改变字号不会按旧页码跳转。
- 阅读同步沿用配对认证，完成 SHA-256 校验后提交；重复同步同一阅读包保留设备上的进度与书签。
- 修复旧阅读页末尾位置误作恢复位置、小字号行缓冲越界、后台预加载与全局画布竞争。上一页使用准确边界，保留最多 256 个近期分页位置。

## 使用

1. 打开项目中的 `apps/inknote-studio/build/InkNote Studio.app`（版本 0.4.1）。
2. 选择「阅读 · 书籍与笔记」→ 书籍 →「导入 EPUB / TXT」。导入后可预览正文。
3. 设备主菜单 → 阅读 →「Wi-Fi 同步内容」。也可从 InkNote 录音准备页向上拨进入传输。
4. Mac 连接设备显示的 InkNote 热点，输入设备地址和本次六位配对码，点击连接。
5. 选中书籍，点击「同步所选到设备」。出现 SHA-256 校验通过后，设备双击 BOOT 退出传输，进入书籍列表。
6. 无需 Wi-Fi 时，可用「导出所选到 TF 卡」选择卡根目录，安全推出后插回设备。

笔记：先在会议纪要中导出 Markdown，再在阅读页切换「笔记」并导入。此版没有自动推送每次录音的摘要，也没有双向编辑。

原创测试书：`releases/light-reading-v0.4/轻阅读使用示例.epub`，包含两章和可供翻页验证的中文正文。Mac 本地书库中已通过实际 UI 导入此书。

## 范围与限制

- 文字轻阅读：图片显示文字占位；不保留复杂 CSS、表格、公式、脚注跳转或固定版式；不支持 DRM、PDF、漫画。
- EPUB 不依赖第三方在线服务，解析使用系统 XMLParser 和 unzip。输入 ZIP 最大 64 MiB，展开总量最大 64 MiB，正文最大 8 MiB，最多 512 章。
- 不支持的 TXT 编码会提示另存为 UTF-8；原设备 TXT 阅读入口仍保留。
- 从书籍较后位置恢复或更换字号后，首次向前翻页需要重建分页，可能较慢；显示加载提示，双击 BOOT/拨轮可返回。
- EPUB 目录目前按正文 spine 章节生成，不支持 EPUB nav/NCX 的多级目录和同一 XHTML 内小节定位。
- 本地书库：`~/Library/Application Support/InkNote/Books/<内容ID>/`。原文件、阅读包和提取文字均保留。
- 设备：`/sdcard/books/<内容ID>/book.txt`、`meta.json`、`progress`、`bookmarks`。失败的临时上传不会出现在书架中。

## 验证与证据

- 原生 Mac UI：成功打开阅读页、导入两章中文 EPUB、显示书名作者和正文预览。应用签名验证通过。
- `tests/book-import/test_import.py`：13 项通过，覆盖章节顺序、中文字节偏移、元数据、UTF-8/UTF-16、损坏包、危险路径、实体、固定版式与加密拒绝等。
- `tests/check_book_upload.py`：25 项通过，运行实际 C++ 上传处理器，覆盖分块接收、摘要校验、未授权、损坏与中断、UTF-8、目录边界、重复保留进度、TF 元数据键顺序兼容和 JSON 深度限制。
- `tests/test_reader_pagination.py`：实际分页函数通过 ASan/UBSan 主机检查，覆盖中文连续性、小字号行界限、末页清理和字号变更定位。
- ESP-IDF 固件构建成功，应用 14,401,808 字节，15 MiB 应用分区可容纳。
- 已通过 USB 刷入应用分区，Hash of data verified；更新后启动日志确认应用加载、PSRAM 测试、TF 卡与音频初始化成功。日志 `logs/light-reading-flash.log`、`logs/light-reading-device.log`；汇总 `logs/light-reading-validation.json`。
- 日志：`logs/light-reading-*-tests.log`、`logs/light-reading-mac-build.log`、`logs/light-reading-build.log`、`logs/light-reading-flash.log`。

尚待设备操作验收：真实 Wi-Fi 配对上传、屏幕字体/残影、目录跳转、书签、退出重进及断电续读、长书性能。主机模拟和编译通过不等同这些实机项目通过。

## 更新与回退

- 固件留档：`releases/light-reading-v0.4/inknote_system.bin`。
- 更新只写应用分区 `0x10000`，不写引导、分区表、NVS 或 SPIFFS，不格式化 TF。
- 更新前固件与 Mac 可执行文件备份：`backups/light-reading-before/`。
- 构建：`bash -c '. scripts/env.sh; idf.py -C apps/inknote-system build'`。
- Mac 首次完整构建：`bash apps/inknote-studio/build.sh`；已有模型完整资源时，可 `INKNOTE_EXECUTABLE_ONLY=1 bash apps/inknote-studio/build.sh` 仅更新可执行文件与签名。
