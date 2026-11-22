# Lab7 iOS 版 APP（AI Badge）

老师的 Lab7 参考实现只给了 Android / 鸿蒙。本项目是按同一份 BLE 协议、用**原生 SwiftUI**
为 iPhone 重写的等价客户端。因为手头没有 Mac，采用 **GitHub Actions 云端 macOS 编译 + Windows
上 Sideloadly 用 Apple ID 自签安装** 的方式出包。

## 1. 功能与协议对照

| 能力 | Android 参考实现 | 本 iOS 实现 |
|---|---|---|
| BLE 扫描/连接 | `BadgeBle.kt` | `BleManager.swift`（CoreBluetooth） |
| 五特征 UUID | `6E400002~0006` | `BadgeProtocol.swift` 逐值一致 |
| MTU | `requestMtu(517)` | iOS 无主动请求 API，自动协商（ESP32 实测 185） |
| 上行音频 | `[seq:u16][ADPCM 160B]` | 同左；固件每帧独立编码，解码端逐帧复位 |
| ADPCM 4:1 | `AdpcmCodec.kt` | `Adpcm.swift`，step/index 表逐值照抄固件 |
| 图像 | 11B 分片头 + 重组 | 同左；**真实帧为 160×120 RGB565**，故障测试图为 JPEG |
| 指令 | `START_MIC / STOP_MIC / SNAPSHOT / AUDIO_FLUSH / …` | 同左 |
| 状态事件 | STATUS JSON（`tpos/state/err/mtu/info`） | 同左 |
| ASR | 端侧 Paraformer（离线模型） | iOS 系统端侧 `SFSpeechRecognizer`（zh-CN） |
| TTS | 系统 TTS → WAV → 16k PCM | `AVSpeechSynthesizer.write` → PCM → 16k |
| 大模型 | OpenAI 兼容 SSE | `LlmClient.swift`（URLSession bytes） |
| 打断 | AUDIO_FLUSH + TPOS | 同左 |

四页 UI：设备 / 预览 / 对话 / 设置。

## 2. 目录结构

```text
BadgeAppIOS/
├── project.yml                  # XcodeGen 工程描述（CI 里生成 .xcodeproj）
├── .github/workflows/ios-build.yml
├── Sources/
│   ├── App/BadgeApp.swift
│   ├── Core/BadgeProtocol.swift
│   ├── Core/Adpcm.swift
│   ├── BLE/BleManager.swift
│   ├── Speech/SpeechRecognizer.swift
│   ├── Speech/TtsSpeaker.swift
│   ├── Net/LlmClient.swift
│   ├── Chat/ChatOrchestrator.swift
│   ├── Store/SettingsStore.swift
│   └── Views/{RootView,DeviceView,PreviewView,ChatView,SettingsView}.swift
└── Support/Info.plist           # 由 xcodegen 生成（已 gitignore）
```

## 3. 构建：GitHub Actions 出未签名 IPA

1. 在 GitHub 新建一个仓库（Private 即可）。
2. 把 **`BadgeAppIOS` 整个文件夹的内容作为仓库根目录** 上传/推送：
   ```bash
   cd BadgeAppIOS
   git init
   git add .
   git commit -m "Lab7 iOS app"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```
3. 打开仓库 **Actions → Build unsigned iOS IPA → Run workflow**。
4. 构建成功后，在该次运行页面底部下载 artifact：`BadgeAppIOS-unsigned-ipa`。
5. 解压得到 `BadgeAppIOS-unsigned.ipa`。

说明：`CODE_SIGNING_ALLOWED=NO` 产出的是未签名包，Sideloadly 会用你的 Apple ID 重新签名。

## 4. 安装到 iPhone（Windows，无需 Mac）

1. Windows 安装 [iTunes](https://www.apple.com/itunes/)（提供 Apple 驱动）和
   [Sideloadly](https://sideloadly.io/)。
2. iPhone 用数据线连接电脑，解锁并点「信任此电脑」。
3. 打开 Sideloadly，把 `BadgeAppIOS-unsigned.ipa` 拖入，`Apple account` 填你的 Apple ID。
4. 点 **Start**，输入 Apple ID 密码（如开启双重认证，需使用 App 专用密码）。
5. 安装完成后，在 iPhone **设置 → 通用 → VPN 与设备管理** 中信任你的开发者证书。
6. 回到桌面打开 **AI Badge**。

> 免费 Apple ID 签名的 App **7 天过期**。到期后用 Sideloadly 重新签名安装即可；
> 想自动续签可改用 AltStore / SideStore（需要常驻一台电脑或使用无线续签方案）。

> 如果安装时报 bundle id 冲突，改 `project.yml` 里的
> `PRODUCT_BUNDLE_IDENTIFIER`（例如 `com.yourname.badgeios`）后重新跑 Actions。

## 5. 运行配置

1. iPhone 与电脑连同一个 Wi-Fi（推荐电脑连手机热点，IP 稳定，如 `172.20.10.x`）。
2. 电脑启动 llama-server，并监听所有网卡：
   ```powershell
   llama-server -m <模型.gguf> --mmproj <mmproj.gguf> --host 0.0.0.0 --port 8080 -c 4096
   ```
3. Windows 防火墙放行 8080（或临时允许 llama-server 的专用网络访问）。
4. 浏览器在手机打开 `http://<电脑IP>:8080/v1/models` 验证连通。
5. App「设置」页填：
   - URL：`http://<电脑IP>:8080/v1/chat/completions`
   - 模型名：`qwen3-vl`（与 llama-server 加载名一致即可）
   - 点「保存」→「测试连接」。
6. 首次运行依次允许：**蓝牙**、**语音识别**、**本地网络**、麦克风（如弹出）。

## 6. 使用流程

1. 「设备」页 → 扫描设备 → 连接 `AI-Badge-BLE`，等待三个 Notify 使能。
2. 「对话」页按住底部按钮说话，松开后：挂件录音 → 端侧识别 → 大模型流式回答 →
   手机 TTS 合成 → ADPCM 下发挂件喇叭播放。
3. 播放中点「打断」，或长按挂件 BOOT 键，均会 `AUDIO_FLUSH` 清队列。
4. 「预览」页开始预览 / 抓拍，图像按分片重组后显示。

## 7. 与 Android 版的差异（重要）

- **MTU**：iOS 不允许 App 主动请求 MTU。CoreBluetooth 与 ESP32 协商通常为 185，
  固件按 `MTU-3-11` 分片，音频单包 161B 仍在单包上限内，无需改动固件。
- **图像格式**：真实帧是 RGB565（`camera.c` 用 `PIXFORMAT_RGB565`，160×120），
  iOS 端自行转 RGBA；只有摄像头故障注入的 `test_img` 才是 JPEG。
- **ASR**：使用系统 `SFSpeechRecognizer`，优先 `requiresOnDeviceRecognition`；
  机型未下载中文离线包时会回退到联网识别，需保持网络。
- **TTS**：`AVSpeechSynthesizer.write(_:toBufferCallback:)` 只在真机可用（模拟器无回调），
  取到 PCM 后线性重采样到 16kHz 再 ADPCM 编码。
- **音频解码**：固件每个 20ms 帧都 `adpcm_reset` 后独立编码，所以 iOS 解码器也逐帧复位；
  Android 参考实现跨帧保持状态，边界会有轻微误差，本版按固件行为实现。

## 8. 常见问题

| 现象 | 排查 |
|---|---|
| Actions 失败在 `xcodegen` | 确认仓库根目录有 `project.yml` |
| App 扫描不到挂件 | 蓝牙权限；挂件是否在广播（串口日志「广播中」） |
| 连接后无音频 | 看「设备」页日志是否有 3 条 Notify 使能；上行帧计数是否增长 |
| 对话提示 LLM 错误 | 手机与电脑是否同网；防火墙；URL 是否 `/v1/chat/completions` |
| 识别一直为空 | 设置 > 隐私 > 语音识别 是否授权；是否下载中文离线语音包 |
| 挂件没有声音 | 音量是否 0；是否已发 `SET_VOL`；TTS 是否在真机运行 |
| 预览图片花屏 | 确认固件为 RGB565 160×120；丢片时 latest-frame-wins 会等下一帧 |

## 9. 验证状态说明

本工程在 Windows 上编写，**未在本地用 Xcode 编译**（没有 Mac）。已做静态自检：
协议字段与固件/Android 逐项对照、Info.plist 权限键齐全、Swift 类型/API 可用性（iOS 16）检查。
首次云端构建如有个别编译告警/错误，按 Actions 日志修正后重跑即可。
