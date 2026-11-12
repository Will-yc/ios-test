# my_flutter_app — 音频验证工程

用来验证音频链路里那些「换个环境就跑不起来」的部分。目前承载两块：

1. **opus / PcmSound 实时播放**（`lib/demo/test_opus.dart`）
2. **WebRTC AEC3 外放回声消除**（`packages/native_aec` + `lib/demo/aec3_test_page.dart`）

---

## AEC3 验证

### 它是干什么的

不戴耳机做双人对录时，扬声器放出来的对方声音会被麦克风再收一遍，混进录音成品里。
AEC3 用「正在播放的 PCM」当参考信号，把这部分回声从采集信号里减掉，只留本端人声。

### 三条验证路径

| 路径 | 验证什么 | 怎么跑 |
|---|---|---|
| **桌面 CLI** | Dart 信号构造 / FFI 通路 / 统计口径 | `LD_LIBRARY_PATH=<含 libnative_aec.so 的目录> dart run tool/aec3_offline.dart` |
| **Android 真机** | NDK 编译 / so 打包 / 运行时符号解析 / 真实 SoC 性能 | `flutter build apk --debug`，装上后点「AEC3 回声消除自测」 |
| **iOS CI** | pod install / xcframework 链接 / C++20 编译 / 符号入库 | push 后自动跑 `.github/workflows/aec3-build-check.yml` |

自测用的是**合成信号**（远端谐波语音 + 80ms 延迟 + 0.35 耦合 + 3% 非线性 + 本端人声），
不需要麦克风、不需要两台手机，所以 Android / iOS / 桌面拿到的是同一道题，结果可直接对比。

### 已验证的结果

| 指标 | Android（PMA120 arm64） | 桌面（x86_64） |
|---|---|---|
| 库加载 | ✅ `m155.8059.4.0` | ✅ 同 |
| ERLE（纯回声段） | **36.5 dB** | 36.5 dB |
| 本端独说保真 | **-0.1 dB** | -0.1 dB |
| 双讲人声保留 | -1.3 dB | -1.3 dB |
| 样本守恒 | 288000 = 288000 | 相同 |
| 6 秒音频耗时 | 107 ms（≈56× 实时） | 202 ms |

iOS 的编译结果看 Actions 里 `AEC3 build check` 的 `iOS (no codesign)` job。

### 合格线

- **ERLE ≥ 25dB** 且 **样本严格守恒** → 通过
- 两端都低于 20dB 才需要排查（先怀疑 xcframework 没链进去 / 头路径不对）
- 双讲 -3~-6dB 是 AEC 的 NLP 正常行为，不是 bug

---

## CI

### `aec3-build-check.yml`（免签名，日常用）

push 到 `main` 且改到 `lib/**`、`packages/native_aec/**`、`pubspec.yaml`、`ios/**`、`android/**` 时自动跑：

- **Android**：`flutter build apk --debug --target-platform android-arm64`，
  然后断言 APK 里同时存在 `libnative_aec.so` 与 `libwebrtc-audio-processing-3.so`
- **iOS**：`pod install` + `flutter build ios --debug --no-codesign`，
  然后 `nm` 断言 `aec3_create` / `aec3_process_capture` 等符号确实进了 Runner 二进制

不需要任何 secrets。

### `ios-release.yml`（出 IPA，手动触发）

只在 Actions 页面手动 `Run workflow` 时跑，需要签名证书。配置：

```
/settings/secrets/actions

base64 -i distribution.p12 | tr -d '\n\r' > p12_base64.txt
base64 -i zyxctest.mobileprovision | tr -d '\n\r' > profile_base64.txt
```

需要的 secrets：`IOS_P12_BASE64`、`IOS_P12_PASSWORD`、`IOS_PROVISION_PROFILE`。

---

## Android ↔ iOS 实测（无耳机对讲 → 导出 WAV）

给真机实测用的唯一动线：**进房 → 双方不戴耳机说话 → 结束导出 wav**。
页面 `lib/demo/aec3_room/handsfree_room_page.dart`，首页第一个按钮；
CI 出来的包带 `--dart-define=ROOM_TEST=true`，装上直接停在这一页。

通信**不再自己起中继**，直接用 App 项目现成的音频房间服务端：

```
wss://appapi.zhiyuexc.com/audiowss        // = HttpConfig_Socket.getSocketUrl
```

两台设备只要能上网就行，不需要同一局域网。协议与 App 逐字段一致：

```jsonc
// 连上先收 "ws_connection_success"
{"type":"join","content":{"roomId":"aec3test","userId":"hf_A"}}   // 两个字段都必须传字符串
// 心跳每 5s：{"type":"heartbeat","content":{}}
// 上行：裸 opus 二进制（16k / mono / 20ms），服务端混音后扣掉发送者自己那份再下发
```

服务端 `mixer.go` 在合成时减掉每个客户端自己的分量（`v -= own * gain`），
所以收到的永远是**对方的声音**——这正好是 AEC 需要的干净参考信号，不会把自己消掉。

### 动线

1. 装包
   - Android：Actions → `AEC3 build check` → artifact `aec3-android-debug-apk`
   - iOS：Actions → `Build Flutter iOS IPA` → artifact `iOS-IPA-room-test`（ad-hoc，只能装到描述文件里登记过的设备）
2. 两端打开 App（ROOM_TEST 构建直接停在实测页）
3. 房间号一致（默认 `aec3test`），**一端选 A 端、另一端选 B 端**
4. 各点「加入房间并开始」，两端「对端」变成 **已进房** 再说话
5. 都不戴耳机、扬声器音量开到常用大小，正常对话 30 秒以上
6. 任一端点「结束并导出 WAV」→ 自动弹系统分享 → 存「文件」/ 发给对方

### 成品

| 项 | 值 |
|---|---|
| 命名 | `handsfree_<A\|B>_<yyyyMMdd_HHmmss>.pcm` → 同名 `.wav` |
| 格式 | 48 kHz / 16 bit / 单声道（AEC 之后的字节） |
| 位置 | App 文档目录，页面上「复制文件路径」可取 |
| 内容 | 只应剩本端人声；开头 1~2 s 是 AEC 收敛期，保留原样 |

### 判读

- 「回声抑制 = 采集电平 − AEC 后电平」：对方说话时 20~30 dB 属正常；
  己方独说时这个值会掉到 0~3 dB（没有回声可消，不是坏了）。
- 成品里听到对方声音 → 先确认 AEC3 是否可用（日志第一行会写）、
  两台设备是否真的连在同一个房间号、以及是否戴着耳机跑（戴耳机没有回声通路，测不出效果）。
- iOS 切到后台/锁屏会被系统掐掉麦克风，实测期间保持前台。

---

## 双人外放免提对讲（调试页，带 AEC 开关/回环）


自测页证明的是「AEC3 这个 DSP 在合成信号上有效」，还不等于「App 里那条链路真的能消掉回声」。
`lib/demo/aec3_room/` 把 `zyxc-record-app` 对讲页的**边录、边播、边存**整条链路搬了过来，
只留验证需要的那部分，结构保持一一对应，方便日后反向迁移。

### 一眼看懂它测什么

```
mic 48k ──► AEC3(48k) ──┬──► .pcm 落盘（成品，AEC 之后的字节）
                        └──► 48k→16k ──► opus 20ms ──► WS 二进制 ──► 对端
                                    ▲
扬声器 ◄── 48k opus 解码 ◄── WS ◄── 对端 ──┘  参考信号 = 真正喂给扬声器的那份字节
```

### 三步跑起来

```bash
# 1) 默认连 App 的服务端，不需要起任何东西；
#    要完全离线（没网/不想碰生产房间）才起本地中继：
#    dart run tool/relay_server.dart --port 8089   → 地址填 ws://<电脑IP>:8089

# 2) 两台手机都装同一个包，进首页点「AEC3 外放免提对讲」
#    服务地址保持默认，房间号都填 1234，一端选 A 端、另一端选 B 端
flutter run --debug

# 3) 手机都**不要戴耳机**、外放音量开到常用大小 →
#    点「连接」→「开始对话」（一端点即可，另一端会收到 start_record 同步开始写盘）
#    →「停止录音」→「导出 WAV」→「分享 WAV」拿文件
```

判读：**A 的 wav 里应该只剩 A 自己说话**，B 的声音（A 外放出去又被 A 麦克风收回来那段）被消掉。
把「AEC3」开关关掉再录一段做对照，差别非常明显。

### 页面上那几个数字怎么读

| 显示项 | 含义 | 期望 |
|---|---|---|
| AEC 抑制量 | `in − out`（dBFS 之差），对方独说时近似 ERLE | 20~35 dB |
| AEC 帧 / 缺参考 | 已处理 10ms 帧数 / 参考不足补零的帧数 | 缺参考应接近 0 |
| 样本守恒 | 进 AEC 的字节 → 出 AEC 的字节 | 严格相等（或差 < 960B） |
| 播放延迟 | 播放侧积压（100ms 安全垫 + 网络抖动） | 100~250 ms |

### 与 App 的对应关系（迁移时按这张表搬）

| App 文件 | 本工程 | 差异 |
|---|---|---|
| `my_dual_recorder_main_page.dart` | `lib/demo/aec3_room/dual_room_page.dart` | 去掉房间业务/转码上传/主题/耳机检测 |
| `my_dual_audio_processing_worker.dart` | `audio_processing_worker.dart` | 去掉上传与元数据；加 `aec_stats` / `file-closed` |
| `my_dual_audio_playback_manager.dart` | `audio_playback_manager.dart` | **删掉 1.25x 变速**（AEC 硬要求） |
| `my_dual_websocket_manager.dart` | `room_socket.dart` | 只留 join/leave/heartbeat/binary/start_record |
| `voip-server`（Go + libopus） | `tool/relay_server.dart` | 两人场景用原包转发代替 MCU 混音 |
| — | `wav_export.dart` | 新增：pcm→wav 流式导出（不整段读内存） |

### 这一版特意做的取舍

- **1.25x 变速彻底删掉**：变速让「参考 ↔ 采集」的延迟持续漂移，AEC 永远在重收敛。
  原工程用 `fixedPlaybackRate: kEnableAec` 关它，这里直接不实现。
- **播放解码到 48k**（不是 16k）：参考信号必须与采集同采样率，否则要多一次上采样，
  既加延迟又在 8k 以上伪造镜像能量。
- **参考信号按 100ms 批量推**（与 `_doFeed` 的 `targetNativeMs` 一致），
  采集按 20ms 处理。离线仿真验证过这个交错的 ERLE = **31.2 dB**、样本 432000=432000。
- **上行仍是 16k opus**：成品求质、传输求通两条独立需求，不为了验证改带宽。
- **一段一文件**：worker 在停止写盘时会关 sink，不重新 `init` 就再也写不进字节
  （表现为"第二次录音 0 字节"）。重新 `init` 只清帧缓存，自适应滤波器保留。

### 本工程做不到的

- **真实扬声器非线性 + 大音量**：只有真机能给。合成信号只带 3% 三次失真。
- **iOS 的音频路由**（听筒/扬声器切换、蓝牙插入拔出）：需要在真机上手动过一遍。
- 两端设备的采样时钟有 ppm 级漂移（播放走 `flutter_pcm_sound`、采集走 `record`，
  是两套独立时钟），长时间对录 AEC 会周期性略微失锁 —— 原工程同样如此。

---

## 目录

```
packages/native_aec/           AEC3 FFI 插件（库、C 桥接、podspec、CMake）
  third_party/webrtc_apm/      预编译库 + 头 + 许可
  src/aec3_bridge.{h,cpp}      C 接口（样本守恒 / 只开 AEC）
lib/demo/aec3_selftest.dart    自测逻辑（纯 Dart，App 与 CLI 共用）
lib/demo/aec3_test_page.dart   自测页 UI
lib/demo/aec3_room/            双人外放免提对讲（AEC3 真实链路验证）
  dual_room_page.dart          页面：连接 / 对话 / 录音 / 导出
  audio_processing_worker.dart worker isolate：AEC + 落盘 + opus
  audio_playback_manager.dart  播放 + 参考信号回喂（无变速）
  room_socket.dart             房间通信（join/heartbeat/二进制透传）
  wav_export.dart              pcm → wav（流式）
  handsfree_room_page.dart     实测页：进房/对讲/导出（唯一动线）
  e2e_selftest_page.dart       真机端到端自测（自动跑，AEC 开/关对照）
tool/aec3_offline.dart         命令行入口
tool/relay_server.dart         零依赖中继（协议与 voip-server 对齐）
tool/analyze_echo.py           离线分析两段 pcm：延迟 / 相关系数 / 逐秒抑制
```

## 真机端到端自测（无耳机外放）

`lib/demo/aec3_room/e2e_selftest_page.dart` —— 进页面**自动跑，不用点屏幕**。
它要验的是桌面上验不了的那一段：扬声器真的出声 → 空气 → 麦克风 → AEC3 → 落盘。

```bash
# 参考延迟补偿可编译期调（下面有实测依据）
flutter run -d <设备> --dart-define=AEC3_E2E=true --dart-define=REF_DELAY_MS=250
```

流程：先录 1s 静音（本底噪声基准），再用同一份 10s 测试信号跑两遍 ——
AEC 开 / AEC 关，信号既喂扬声器也作为参考信号喂 AEC3，两段 pcm 落在
`app_flutter/aec3_e2e/`。取回并离线分析：

```bash
adb exec-out run-as com.example.my_flutter_app cat app_flutter/aec3_e2e/aec_on.pcm > aec_on.pcm
adb exec-out run-as com.example.my_flutter_app cat app_flutter/aec3_e2e/aec_off.pcm > aec_off.pcm
python3 tool/analyze_echo.py .        # 需要 numpy
```

**读数时注意两件事**（踩过）：

1. 统计窗口必须落在信号后段（本项目取 7.0~10.9s）。播放→采集的端到端延迟在
   这台机器上是 321~352ms，AEC3 要 5s 以上才收敛，窗口太靠前会读到"半收敛"，
   把 24dB 误判成 8dB。
2. 必须同时看本底噪声。残余一旦压到本底，读数就只有 5~7dB —— 那是测量下限，
   不是算法上限。`analyze_echo.py` 会把逐秒曲线和相关系数一起打出来。

PMA120 实测（媒体音量 70/160，房间安静）：

| 场景 | 强回声段抑制（语音带） | 整体读数 | 残余与参考的相关系数 |
|---|---|---|---|
| 参考延迟补偿 250ms | **24.6 dB** | 15.4 dB（触底） | −0.021（已无线性回声） |
| 不补偿 | 20~22 dB | 14.2 dB（触底） | — |

## 已知限制

- **预编译包没有 `x86`**，只有 `arm64-v8a` / `armeabi-v7a` / `x86_64`，所以 ABI 必须限定在这三个
- 双讲时本端人声会被压 3~6dB，这是 AEC3 NLP 的固有代价（独说时无损）
- 参考延迟补偿用的是固定值。换机型/换播放路径后延迟会变，需要重测
  （`tool/analyze_echo.py` 第一段就是量这个）
- 首句仍有风险：延迟越大收敛越慢，很短的对话（<3s）开头可能带回声
