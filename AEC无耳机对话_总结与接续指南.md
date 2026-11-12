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
