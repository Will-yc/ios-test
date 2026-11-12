# AEC 无耳机对话 · 项目总结与接续指南

> 换账号接续用。读完这份就能无缝接手，不必重跑历史验证。

## 一、这个项目在做什么

在 `ios-test`（公开仓库 `Will-yc/ios-test`）里验证「**两人不戴耳机、外放对讲**」时，
用 **WebRTC AEC3** 做回声消除，成品录音存 **48kHz 全频带 PCM** 并导出 WAV。

目标场景：两台手机（Android ↔ iOS）直连生产房间服务 `wss://appapi.zhiyuexc.com/audiowss`，
无耳机对话，成品里**只剩本端人声**（对方声音被 AEC 消掉），且要达到 TRTC 级别的
「贴脸也不啸叫」。

## 二、代码位置（全部在 ios-test，App 生产代码零改动）

```
lib/demo/aec3_room/
├── handsfree_room_page.dart        # 唯一实测动线页（进房→对讲→导出WAV+分享）
├── audio_processing_worker.dart    # worker isolate：48k采集→AEC3→落盘pcm / 编码opus
├── audio_playback_manager.dart     # 播放 + 参考信号回喂 + duck
├── loop_gain_guard.dart            # 采集侧啸叫守卫 + 环路增益守卫
├── delay_calibrator.dart           # 参考延迟自动标定（31位LCG长周期PN）
├── residual_gate.dart              # 下行相关门（成品彻底无回声）
├── room_socket.dart                # 房间 WS 通信
├── wav_export.dart                 # 流式 pcm→wav
└── dual_room_page.dart             # 旧调试页（有参考未对齐问题，别用）
packages/native_aec/
├── src/aec3_bridge.cpp             # C++ 桥接：AEC3 + 高频旁路（线性相位FIR）
└── lib/native_aec.dart             # Dart FFI 壳
tool/
├── analyze_echo.py / analyze_spectrum.py / analyze_howling.py
└── relay_server.dart               # 零依赖中继（仅本地验证用，实测走生产服务端）
```

`lib/main.dart` 首页第一个按钮进实测页；`ROOM_TEST` / `AEC3_E2E` 用 `String.fromEnvironment(...)=='true'` 判断。

## 三、已完成的技术验证（不要再重跑）

| 项目 | 结果 |
|---|---|
| 中继协议 | 11/11 通过 |
| wav 导出 | 逐字节一致 |
| worker 交错时序 AEC | ERLE 31.2dB（桌面仿真）|
| 真机 AEC 收敛 | 残余与参考相关 −0.021（关时 +0.477），样本守恒 |
| 高频旁路（TRTC式）| 8–20kHz 恢复 +40.6~42.9 dB，线性相位FIR 65taps 群延迟0.67ms |
| 残留门判据 | 纯回声ρ=1.0→压到底、纯本端ρ=0→保留、双讲ρ=0.707→压掉，全绿 |

## 四、关键结论（铁律，别再踩）

### 1. 成品有对方声音 ≠ AEC 没消
先量「延迟副本」：在成品里搜 `x(t)` 与 `x(t−350ms)` 的自相关。若 <0.1，说明线性回声
**已经消掉**，剩下的是双讲泄露 + 厂商非线性，别去调 AEC 参数，加/调 residual_gate。

### 2. 啸叫 = 闭环增益过 1，不是 AEC 算法坏了
决定性证据是**时间线对齐**：音量档 vs 起振时刻。实测「音量 4 档 → 3 秒后自激 →
音量拉 0 → 衰减」。啸叫在 **raw（AEC 前）就存在**，且是跳频间歇自激（峰频 std=632Hz、
包络 CV=1.26），不是等幅单频 —— 所以「800ms 等幅单频」判据永远命中不了。

### 3. 参考信号必须延迟对齐（分平台）
- Android 实测 321~352ms → 补 250
- iOS 实测 130~160ms → 补 100（注释里自认「未实测」，优先用标定测出真值）
- **宁欠勿过**：推满变负延迟，AEC 直接归零。现在已支持运行时可调 + 一键标定。

### 4. TRTC 的差距是结构性的
TRTC 手机端不关硬件 3A、动态对齐、AEC 后还有 NLP 残留抑制、AGC 钳位 + 专门啸叫抑制。
我们为了 20kHz 成品把系统 3A 全关了（`handsfree_room_page.dart` 里 `audioSource: mic`
+ `modeNormal` + `autoGain/echoCancel/noiseSuppress: false` + `contentType: music`），
只剩单层 AEC3。**TRTC 做的是「全带 3A」，不是「关 3A 换带宽」**。

### 5. 三个 dart-define 开关（都用 String.fromEnvironment）
| 开关 | 默认 | 作用 |
|---|---|---|
| `FULLBAND` | true | 高频旁路，成品 8kHz 以上原样取采集 |
| `RESIDUAL_GATE` | true | 下行相关门，成品彻底无回声 |
| `KEEP_RAW` | true | 额外落 AEC 前 `_raw.pcm`，离线算真实 ERLE |

## 五、待办（接手后按顺序做）

1. **双端出包重测**：提交 `96e266f` 已推送，但还**没出包**。GitHub 打 iOS IPA、
   本机打 Android APK 装真机（命令见下）。
2. **真机调 residual_gate 阈值**：`rhoFull=0.55` 是合成信号标定，真机 AEC 已消大部分
   线性回声，残余 ρ 可能偏低。若「对方单独说话还有残响」→ 把 `rhoNone` 降到 0.1、
   `rhoFull` 降到 0.4 更激进。
3. **测 iOS 真实延迟**：用页面「标定延迟」按钮实测，替代猜测的 100ms。
4. **两端 wav + raw 都留**，发回来做互相关算真实 ERLE 和 20kHz 恢复量。
5. 未验证：loop_gain_guard / delay_calibrator 的**真机行为**（只做了纯 Dart 逻辑验证）。

## 六、出包命令（照抄）

### Android（本机打包 + 安装，约 1~2 分钟）
```bash
cd /home/ycwork/project/zyxc/codec/app/download/ios-test
export TMPDIR=/home/ycwork/project/zyxc/codec/app/download/ios-test/.workbuddy/tmp/fbuild
mkdir -p "$TMPDIR"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  GRADLE_USER_HOME=/home/ycwork/.gradle \
  /home/ycwork/software/flutter/bin/flutter build apk --debug \
  --dart-define=ROOM_TEST=true --dart-define=ROOM_ID=aec3test \
  --dart-define=KEEP_RAW=true
adb uninstall com.example.my_flutter_app   # 必须先卸（CI keystore 与本机不同，否则签名冲突）
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### iOS（GitHub Actions 打 IPA）
```bash
TOKEN=$(grep -o 'https://[^:]*:[^@]*@github\.com' ~/.git-credentials | head -1 | sed 's#https://[^:]*:##; s#@github\.com##')
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/Will-yc/ios-test/actions/workflows/ios-release.yml/dispatches \
  -d '{"ref":"main"}'
# 等 5 分钟，查 run id 后下载 artifact zip 解压得到 my_flutter_app.ipa
```

### iOS 装真机（pymobiledevice3）
```bash
sudo systemctl start usbmuxd   # 若 usbmuxd inactive
source ~/.venv/mobile/bin/activate
python -m pymobiledevice3 usbmux list
python -m pymobiledevice3 apps install /home/ycwork/Downloads/ios-ipa-fullband/my_flutter_app.ipa
python -m pymobiledevice3 syslog live | grep -i flutter
```

## 七、GitHub 推送（网络坑）

- 代理会抖，先测连通：直连 `env -u http_proxy ... curl https://api.github.com`，
  或 `-x http://127.0.0.1:7890`（本地 Clash）。
- 直连通时用 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY git push origin main`
- token 在 `~/.git-credentials`
- 已把 `aec3-build-check.yml` 的 push 触发去掉，**GitHub 只打 iOS**，Android 全本机。

## 八、拉回真机录音分析

```bash
# Android（raw 是 AEC 前、不带 raw 的是成品，都是 48k/单声道/int16）
adb exec-out run-as com.example.my_flutter_app ls -la app_flutter/
adb exec-out run-as com.example.my_flutter_app cat app_flutter/<文件名> > <本地>

# 分析脚本（numpy，venv 在 /home/ycwork/.workbuddy/binaries/python/envs/default）
/home/ycwork/.workbuddy/binaries/python/envs/default/bin/python tool/analyze_howling.py raw.pcm out.pcm
```

**iOS 拉录音的坑**：当前 IPA 的 Info.plist **缺 `UIFileSharingEnabled`**，
`apps afc --documents` 报 InstallationLookupFailed，拉不到 iOS 端文件。
要做两端互相关得先加文件共享再出包。

## 九、两个已知真 Bug（还没修）

1. **粘包**：`room_socket.dart:136` 直接 `jsonDecode(data)`，服务端把 `leave`+`join`
   塞进同一帧 → `FormatException` → 整帧两条消息全丢，成员进出状态错乱。
2. **iOS 文件共享**：见上，Info.plist 缺 `UIFileSharingEnabled`。

## 十、仓库当前状态

- 最新提交 `96e266f`（本地 = 远程 `origin/main`），已推送。
- 分支 `main`，工作区干净（无未提交改动）。
- 历史提交：`4ebc39f`(全频带) → `8ff23f7`(啸叫分平台延迟) → `ee95e43`(参考对齐+去削波)
  → `7832567`(实测页) → `7660e59`(AEC3 集成) → `9515f94`。

## 十一、2026-11-12 复测：两台设备**不在同一空间**仍啸叫 → 采集侧陷波（新增层）

真机（Android↔iOS，两台不在同一房间）成品 WAV 的量化结论：

| 观测量 | 值 | 含义 |
|---|---|---|
| 1.9kHz 频带包络 | A 在 13s 起振 → 45s 平台期 −33dBFS；B 滞后 **0.7s** 同步起振 | 振荡在**网络环**里传播，不是本地声学直达 |
| 自相关峰 | **1.14s（0.59）** 且 2.28s = 2× | 回路一圈 ≈1.14s |
| 谱峰漂移 | 1.5~3kHz 之间随机跳（1523~2977Hz），非等幅单音 | 多模自激，听感是「一片吼叫/杂音」 |
| 电平 | 稳定在 −33dBFS 三十秒不衰减 | 有增益自动补偿托住（实为 iOS 上行 AGC） |
| 谱平坦度 | 有声帧中位 0.0039 | 仍以谐波/窄带为主，不是白噪声 |

**为什么不在同一空间还会啸叫**（关键认知，别再问第二遍）：
回路声耦合只发生在**各自设备「自己的扬声器 → 自己的麦克风」**这一段：
`A 麦 → 上行 → B 外放 → B 麦 → 上行 → A 外放 → A 麦`。
房间不共享只切断了 A、B 之间的**空气直达**（那条路本来就被 AEC 当参考消掉），
切不断这条环。只要 AEC 没把自回声消干净（参考延迟一错就废），环增益 >1 就自激。

**本次改动（`96e266f` 之后新增）**：
1. `lib/demo/aec3_room/howl_notch.dart`：采集侧自适应陷波（RBJ 二阶，Q=f/160Hz，
   深度 22dB，最多 3 个，频点平滑漂移、无目标 bit-exact 直通）。作用在 AEC 之后、
   编码/落盘之前 → **上行与成品同时生效**（这一点和 `residual_gate` 不同，gate 只清成品那一路）。
2. 页面检测器 `_startNotchDetector`：每 250ms 读 `LoopGainGuard.lastPeakHz/lastPeakQDb`，
   起振或窄峰突出 ≥14dB 就锁频下发，6s 未刷新自动淘汰（worker 侧平滑淡出）。
3. **上行 AGC 默认关**（`kUpstreamAgc`，`--dart-define=UPSTREAM_AGC=true` 可开回）：
   它在环路里等于自动补增益，把振荡托在稳态。
4. 开关：`--dart-define=HOWL_NOTCH=false` 可退回旧行为做 A/B。

**验证**：`dart analyze` 全绿；`.workbuddy/tmp/verify_notch.dart` 6 条断言全过
（1.92kHz 压 −22.0dB、500Hz 仅 −0.00dB、漂移后新频点 −22.0dB 且旧频点恢复 −0.09dB、
空目标 bit-exact、清空后自动释放）。**待真机复测**：重新出包后看状态卡「啸叫陷波」是否
锁到 1.8~2.0kHz，以及成品里该频带是否掉到 −70dBFS 以下。

## 十二、2026-11-12 第二轮复测修复（尖叫 / 对方声音 / 底噪）

真机第三版产物（`/home/ycwork/Downloads/audio/test/`，A=Android 87.36s / B=iOS 88.30s）
量化结论与对应改动：

### 1. 尖叫声 —— 陷波误锁人声基频（上一轮已修）+ 守卫误 duck（本轮修）
- 状态卡铁证：`啸叫陷波 挖 375/375/2016Hz`、`窄带峰 703Hz Q=20dB`、守卫 `已触发 21 次`。
- 根因：守卫峰搜索从 **187Hz** 起，人声基频正好在里面；`isDucking` 是「能量在涨」的
  粗判据，人一开口就成立 → 陷波每 250ms 锁一次基频。
- 本轮：`LoopGainGuard.peakLowBin = 26`（**~1.2kHz**），峰搜索与 Q 的邻带统计同区间。
  实测啸叫在 1.5~3kHz，覆盖得到；基频与低次谐波彻底不参与判决。
  页面侧陷波频段（1200~6000Hz）+ 连续确认 750ms 是上一轮就有的双重保险。

### 2. 对方声音被录进来 —— 相关门**从来没生效过**（本轮根因修复）
- 上一版用「当帧参考」与「当帧采集」做零延迟相关，注释写「页面已用 REF_DELAY 对齐」。
  **这是误判**：页面延迟 250ms 只是让 AEC3 看到较小延迟；采集里此刻的回声对应的是
  「播放缓冲 + 声学路径 + 页面延迟」之前送出的字节。用真机 wav 量出来 A 成品与 B 成品
  在**零延迟处 rho=0.001**，在正确延迟处 rho 0.23~0.52 —— 即门一直判「不是回声」，从未压过。
- 本轮：门**自己搜延迟**。粗搜用 4ms 块 RMS 包络（200ms 探针；冷启动 600ms），
  解决「波形相关在整数个基音周期处有等价峰」——实测会把 500ms 搜成 166ms；
  再取包络 top3 候选做全率波形复筛（波形对跨周期偏移敏感，两层互补）；
  最后加「留在原位」先验（延迟是缓变的，等价峰不跳）。
- 判决新增**能量兜底**：下行在响、本帧比参考低 14dB 以上 → 本端没人说话 → 直接压到
  −34dB。新增**下行静默直通**硬保护：参考电平低于 −55dBFS 时无回声可消，绝不误压本端。
- 作用域修正：这一层**只进落盘成品，不进上行 opus**（对讲里整段压会让对讲变半双工）。

### 3. 底噪大 —— 静音期嗡鸣 + 高频嘶声（本轮新增一层）
- 实测：安静帧 `0-4k` 比 `4-8k` 高 **27dB**；120~130Hz 有窄带峰（占安静期能量 ~36%，
  A/B 两端同频 → 环境嗡鸣）；12~18kHz 有嘶声；DC 偏置只有 +1.8 LSB（**不是直流问题**）。
  iOS 底噪 −57dBFS 比 Android −65dBFS 更吵。
- 本轮新增 `noise_gate.dart`：60Hz 二阶高通（次声/缓慢漂移）+ 谷值追踪噪底 +
  逐帧判「够不够像语音」（高于噪底 9dB 立刻全开，低于 4dB 压到 −19dB），帧内线性插值。
  **只压静音帧**，语音帧 −0.22dB（实测），字头损失 1.6dB。
- 顺序：`AEC3 → 陷波 → 相关门（判据用未压的真实能量）→ 底噪门 → 落盘/上行`。
  底噪门若放到相关门之前，会把弱语音压成「能量远低于参考」，被兜底判成残余整句砍掉。

### 验证（离线断言，全部通过）
- `.workbuddy/tmp/verify_gate.dart` 10 条：纯回声 200/350/500ms 均搜到 0 误差并压 35.9dB；
  下行静默时本端 0.00dB 变化；双讲只 −0.2dB；延迟 300→450ms 漂移跟随到 450ms 且仍压住。
- `.workbuddy/tmp/verify_noisegate.dart` 5 条：静音期 −19.4dB、纯语音 −0.22dB、
  字头 −1.6dB、12Hz 次声 −24.9dB。
- `.workbuddy/tmp/verify_notch.dart` 6 条：仍全过（1.92kHz −22dB / 空目标 bit-exact 等）。
- 状态卡新增「底噪门」「残留门 对齐 xxx ms（ρ=x.xx）」；未开录时统一显示「— 待开录」，
  避免再把初始值读成「被关掉」。

### 真机复测要点
1. 进房后先看状态卡「残留门」是否显示**对齐 xxx ms**（合理值 40~620）。显示「正在搜」或
   ρ 长期 < 0.2，说明参考链路本身有问题，先查那个，别调阈值。
2. 单讲（只有对方说）：成品应几乎彻底安静（先前残余约 −32dBFS，现在目标 < −60）。
3. 静音期：底噪门应显示噪底 −60~−70dBFS 区间；成品里不应再有 120Hz 嗡鸣与高频嘶声。
4. 啸叫：状态卡「啸叫陷波」不应再出现 1.2kHz 以下的频点。

## 十三、2026-11-12 第三轮：参考 TRTC 通话档，压「网络环路啸叫」

用户反馈：仍有噪音、对话很不稳定、随时突然啸叫（两台设备**不在同一空间**）。
指定参考 `download/TRTC_Flutter-master/`，「有合理适用的直接参考调整」。

### 根因升级：这不是本地啸叫，是**网络声学环路**
- 环路：A 麦→上行→B 外放→B 麦→上行→A 外放→A 麦。分房间**断不开**这个环。
- 一圈往返 ~1.1s，远超 AEC3 的延迟跟踪能力 → 啸叫期 AEC3 的 ERLE≈0（raw vs 成品实测）。
  我们之前所有「本地 AEC/陷波」都在跟一个**不在本地**的环路较劲。
- 环路增益 >1 就自激。要熄振，必须把**每一跳的残余**压下去、把环路增益压到 1 以下。

### TRTC 的可借鉴结论（Explore 逐文件核对）
1. **通话一律 speech 档 + 系统 3A**：Android `VOICE_COMMUNICATION`、iOS `voiceChat`(VPIO)。
   系统 AEC 用 **HAL 里真实的播放参考**，不用猜 REF_DELAY，收敛快、尾长覆盖好。
   （`ITXDeviceManager.h`、`trtc_cloud.dart` startLocalAudio、`audio_call_state.dart`）
2. **先 AEC、再分叉**：`onCapturedAudioFrame` 拿到的已是 ANS/AEC/AGC 处理后的帧。
3. **播放音量默认 50，从不拉满**（`audio_quality_state.dart`）；媒体音量全频带只用于
   耳机/录音场景，**不用于外放对讲**。
4. 自定义采集会破坏 AEC；啸叫有专门告警码 7002。

### 本轮改动（commit bd2c408）
1. **系统 3A 上行 `SYS_3A`（默认开，`--dart-define=SYS_3A=false` 可回退 A/B）**：
   - **Android 双流**：成品链**保持裸麦 48k + 我们的 AEC3**（保住已验收的 20kHz 音质）；
     另开一条 **16k `VOICE_COMMUNICATION` + AEC/NS/AGC** 流，系统处理后**直接编码上行**。
     不动 AudioManager 全局模式（保持 modeNormal，避免把裸麦流/播放带偏）。
     **回退**：该流启动失败 / 连续 3s 全数字零 / 3s 无数据 → 自动切回 worker 上行（无断档）。
   - **iOS 单流**：系统不允许两条采集流，直接在这条流开 **VPIO**（record 插件把
     `echoCancel=true` 映射成 `setVoiceProcessingEnabled`），会话模式 `voiceChat`。
     代价：iOS 采集带宽可能被压到语音档（TRTC 通话同样如此）；我们的 AEC3/门链保留作第二层。
2. **播放增益默认 100%→70%**（TRTC 用 50）：环路增益与播放音量成正比，直接 −3dB 余量。
3. **啸叫检测改投票式**（`LoopGainGuard`）：最近 500ms 窄带峰投票占比判啸叫，容忍间歇
   bursts 与跳频。真机第四版 raw 离线回放：**首锁 25.8s→5.0s**，0-4s 纯语音**零误报**；
   投票≥0.2 时**持续 duck**（不再 3s 固定恢复后复燃），安静段才回升。
4. **陷波双侧**：锁定频点同时下发**采集侧 + 播放侧**两个陷波器（`_playNotch` 挂在
   `_doFeed`，先于 duck/参考取出，AEC 参考仍=扬声器字节）。环路一圈各挖 22dB=44dB。
   带宽 160→240Hz，跟得上跳频。
5. **修成品绕过底噪门的旁路**：落盘链路补第二个 `NoiseGate` 实例（旧版只接了上行，
   成品静音期只压 1.7dB，应 ~19dB）。
6. 相关门阈值 `rhoFull 0.50→0.40 / rhoNone 0.16→0.10`。

### 验证（离线，全部通过）
- `dart analyze lib/demo/aec3_room/` 全绿。
- `verify_v4_chain.dart`（已改投票式）：真机 raw 回放，0-4s 语音 vote≤0.04 无锁无触发；
  5.0s 啸叫起振即锁 2016Hz 并 duck；投票持续期 duck 钉在 0.25，安静段回升、复燃再触发。
- `verify_notch / verify_noisegate / verify_gate` 回归全过（240Hz 带宽、新 rho 阈值下）。

### 出包 / 装机
- Android：本机 `flutter build apk --debug`（+`SYS_3A=true`），`adb uninstall` 后 install，
  17:26 装到 192.168.3.69:5555，启动正常（新装弹麦克风授权）。
- iOS：push bd2c408 → 触发 `ios-release.yml`（run 43191820850）→ 下载 IPA → pymobiledevice3 装机。

### 真机复测要点（本轮）
1. 状态卡新增「**系统3A上行**」：Android 应显示「开 · VOICE_COMM 双流」；若显示「回退」，
   说明第二条流被系统抢占，看日志回退原因（此时上行仍可用，只是回到 AEC3 链）。
2. **重点验证啸叫是否还起**：两端正常对话 30s+，不应再出现金属尖叫。若仍偶发，看守卫
   「已触发 N 次」与「啸叫陷波」锁频——现在应 5s 内锁到 1.5~3.8kHz 并双侧挖。
3. iOS 成品带宽：VPIO 可能收窄高频，属预期取舍（TRTC 通话档同样）；要保 iOS 全频带可
   `SYS_3A=false` 出包 A/B，但啸叫抑制会弱。
4. Android 成品仍应 20kHz 全频带（双流设计，裸麦链没动）。
