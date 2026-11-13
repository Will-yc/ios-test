# AEC 无耳机对话 · 项目总结与接续指南

> 换账号/换机器接续用。读完这份就能无缝接手，不必重跑历史验证。
>
> **2026-11-13 换地方开发 · 最短上手路径**
> 1. 读第十节（分支/提交现状：默认分支 `main`，当前 `5c0d3da`）；
> 2. 读第二节（文件清单，含本轮新增 `comfort_noise.dart`）；
> 3. 读第五节（现在该做什么）与第六节（出包命令，Android 用 `--profile`）；
> 4. 读第二十节（本轮「频谱断裂」根因/修复/诊断三件套，**下手前必读**）；
> 5. 分析成品：`python3 tool/analyze_product_health.py <wav...>`。
>
> 硬约束：① 成品 bar = 48k 全频带 + 只本端 + 自然底噪 + 无啸叫；② 严禁装第三方
> 原生包；③ 本机 7891 代理是坏的，git/curl 必须绕开（第七节）；④ token 在
> `~/.git-credentials`，只进变量，严禁打印。

## 一、这个项目在做什么

在 `ios-test`（公开仓库 `Will-yc/ios-test`）里验证「**两人不戴耳机、外放对讲**」时，
用 **WebRTC AEC3** 做回声消除，成品录音存 **48kHz 全频带 PCM** 并导出 WAV。

目标场景：两台手机（Android ↔ iOS）直连生产房间服务 `wss://appapi.zhiyuexc.com/audiowss`，
无耳机对话，成品里**只剩本端人声**（对方声音被 AEC 消掉），且要达到 TRTC 级别的
「贴脸也不啸叫」。

## 二、代码位置（全部在 ios-test，App 生产代码零改动）

```
lib/demo/aec3_room/
├── handsfree_room_page.dart        # 唯一实测动线页（进房→对讲→导出WAV+分享+诊断落盘）
├── audio_processing_worker.dart    # worker isolate：48k采集→AEC3→门链→底噪垫→落盘/编码
├── audio_playback_manager.dart     # 播放 + 参考信号回喂 + duck
├── loop_gain_guard.dart            # 采集侧啸叫守卫（1.2~9kHz）+ 环路增益守卫
├── howl_notch.dart                 # 二阶陷波组：页面检出啸叫频点后下发
├── residual_gate.dart              # 下行相关门（自搜延迟，成品彻底无回声）
├── noise_gate.dart                 # 采集侧底噪门（谷值追踪噪底，成品只留本端）
├── comfort_noise.dart              # 底噪垫（只补差额，防门链串联把成品压成数字静音）
├── room_socket.dart                # 房间 WS 通信
├── wav_export.dart                 # 流式 pcm→wav
├── e2e_selftest_page.dart          # AEC3 端到端自检页（离线断言用）
└── dual_room_page.dart             # 旧调试页（有参考未对齐问题，别用）
packages/native_aec/
├── src/aec3_bridge.cpp             # C++ 桥接：AEC3 + 高频旁路（线性相位FIR）
└── lib/native_aec.dart             # Dart FFI 壳
tool/
├── analyze_echo.py                 # 回声/延迟互相关（numpy）
├── analyze_spectrum.py             # 长时平均频谱 / 频段电平（numpy）
├── analyze_product_health.py       # 成品健康检查：数字静音断口 + 持续性窄带坑（纯 stdlib）
├── aec3_offline.dart               # 纯 Dart 离线跑 AEC3 链路
└── relay_server.dart               # 零依赖中继（仅本地验证用，实测走生产服务端）
```

> `delay_calibrator.dart` 已在 UI 精简提交 `efd6cb4` 中删除（参考延迟改由相关门
> 自己搜，标定功能冗余）。

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

### 5. dart-define 开关（全部用 String.fromEnvironment，默认值写在代码里）
| 开关 | 默认 | 作用 |
|---|---|---|
| `FULLBAND` | true | 高频旁路，成品 8kHz 以上原样取采集 |
| `RESIDUAL_GATE` | true | 下行相关门，成品彻底无回声 |
| `RESIDUAL_GATE_DTLK` | true | 双讲保护（双讲时少压，保护本端） |
| `NOISE_GATE` | true | 采集侧底噪门（谷值追踪噪底） |
| `COMFORT_NOISE` | true | 底噪垫（只补差额）；`false` 可复现「频谱断裂」对照 |
| `HOWL_NOTCH` | true | 采集侧陷波组（1.5kHz 以上频点） |
| `KEEP_RAW` | true | 额外落 `_raw.pcm` / `_ref.pcm` / `_stats.log`，离线算真实 ERLE |
| `UPSTREAM_AGC` | false | 上行 AGC（默认关：会在啸叫回路里把振荡托稳） |
| `SYS_3A` / `SYS_3A_DUAL` | false | 系统 3A（关：与 AEC3 串联会双处理） |
| `PIN_MIC` | false | 采集钉住单一麦克风（排查换麦导致的音色跳变） |

## 五、待办（接手后按顺序做）

> 2026-11-13 第五轮收尾时的真实状态。旧的「先去出包/调 rhoFull」已完成，别重跑。

1. **双端跑一轮 KEEP_RAW 录制**（Android 已装 `main@5c0d3da`；iPhone 待连上装 IPA，
   见第六节）。每端至少：安静 5s → 对讲 20s → 再安静 5s；中间让对方说整句、
   本端说整句，最好制造一次同时说话（双讲）。
2. **拉回三件套算 ERLE**：`_raw.pcm`（AEC 前）、`_ref.pcm`（AEC 实际参考）、
   `_stats.log`（每秒一行）。用互相关找真实回声延迟，用 in/out 差估 ERLE。
   这一步是回答「用户说的回音到底在成品里，还是本地播放出来的」的唯一硬证据。
3. **先跑 `tool/analyze_product_health.py`** 看成品有没有 >=5ms 连续零采样
   （本轮修的断裂是否真的消失），再看长时平均频谱有没有持续性窄带坑。
4. **听感确认底噪垫的量**：`COMFORT_NOISE=false/true` 各录一条对比。垫高了会
   变「沙沙响」，垫低了断裂会回来（见第二十节）。
5. **服务端延迟（Tier 2）不解决，门的压制上限就是对话天花板**：audiowss 单向
   2~3.6s。这个不是 App 侧能修的，但每次分析成品都要把它当成第一嫌疑。
6. 仍未验证：`loop_gain_guard` / `howl_notch` 的真机长期行为（只做了纯 Dart +
   离线录音验证）。

## 六、出包命令（照抄）

### Android（本机打包 + 安装，约 1~2 分钟）
```bash
cd /home/ycwork/project/zyxc/codec/app/download/ios-test
export TMPDIR=/home/ycwork/project/zyxc/codec/app/download/ios-test/.workbuddy/tmp/fbuild
mkdir -p "$TMPDIR"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  GRADLE_USER_HOME=/home/ycwork/.gradle \
  /home/ycwork/software/flutter/bin/flutter build apk --profile \
  --dart-define=ROOM_TEST=true --dart-define=ROOM_ID=aec3test \
  --dart-define=KEEP_RAW=true
adb uninstall com.example.my_flutter_app   # 必须先卸（CI keystore 与本机不同，否则签名冲突）
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```
> 真机测音频一律用 `--profile`：`--debug` 的 JIT 抖动会让采集/播放回调掉帧，
> 表现出来的「杂音」是打包方式造成的，不是算法。只有排查 Dart 异常才用 `--debug`。

### iOS（GitHub Actions 打 IPA）
```bash
# 本机 7891 代理是坏的（curl 000），API 必须 --noproxy。token 只进变量，别打印
TOKEN=$(grep -o 'https://[^:]*:[^@]*@github\.com' ~/.git-credentials | head -1 | sed 's#https://[^:]*:##; s#@github\.com##')
curl --noproxy '*' -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/Will-yc/ios-test/actions/workflows/ios-release.yml/dispatches \
  -d '{"ref":"main"}'
# 约 5 分钟后按 commit 查 run：
curl --noproxy '*' -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/Will-yc/ios-test/actions/runs?per_page=5" | grep -E 'run_number|head_sha|status|conclusion'
# 再下 artifact iOS-IPA-room-test（zip 里是 my_flutter_app.ipa）
```

### iOS 装真机（pymobiledevice3）
```bash
sudo systemctl start usbmuxd          # 若 usbmuxd inactive
source ~/.venv/mobile/bin/activate
python -m pymobiledevice3 usbmux list # 必须先看到设备 UDID，否则后面全失败
python -m pymobiledevice3 apps install /tmp/ios_ipa_5c0d3da/my_flutter_app.ipa
python -m pymobiledevice3 syslog live | grep -i flutter
```

## 七、GitHub 推送（网络坑）

- 代理会抖，先测连通：直连 `env -u http_proxy ... curl https://api.github.com`，
  或 `-x http://127.0.0.1:7890`（本地 Clash）。
- 直连通时用 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY git push origin main`
- token 在 `~/.git-credentials`
- 已把 `aec3-build-check.yml` 的 push 触发去掉，**GitHub 只打 iOS**，Android 全本机。

## 八、拉回真机录音分析

### 8.1 产物说明（KEEP_RAW=true 时同目录一次落四份）
| 文件 | 内容 |
|---|---|
| `handsfree_X_时间.wav` / `.pcm` | **成品**（门链 + 底噪垫之后，真正会播给对方/分享的） |
| `handsfree_X_时间_raw.pcm` | AEC **之前**的采集（含回声、底噪） |
| `handsfree_X_时间_ref.pcm` | AEC **实际喂进去的参考**（播放缓冲那一份，不是网络收到的原始包） |
| `handsfree_X_时间_stats.log` | 每秒一行：`t= in= out= lag= rho= floor= notch= vote= peak= duck= frames= starved=` |

全部 48k / 单声道 / int16-LE。

### 8.2 Android（adb）
```bash
adb exec-out run-as com.example.my_flutter_app ls -la app_flutter/
adb exec-out run-as com.example.my_flutter_app cat app_flutter/<文件名> > <本地>
```

### 8.3 iOS（pymobiledevice3，文件共享已开）
`ios/Runner/Info.plist` 已含 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
= true，所以 `--documents` 能进沙盒。`apps afc` 是**交互式 shell**（不是一次性命令）：
```bash
source ~/.venv/mobile/bin/activate
python -m pymobiledevice3 apps afc --documents com.zhiyuexctest.app
# 进去以后：
ls
pull handsfree_A_20261113_162048.pcm      ./a.pcm
pull handsfree_A_20261113_162048_stats.log ./a_stats.log
# 也支持 cat / rm / stat / walk / pwd / cd
```
> `InstallationLookupFailed` 只说明「这台设备上没装该 bundle id」。iOS 端 id 是
> `com.zhiyuexctest.app`（Android 是 `com.example.my_flutter_app`，两者不同），
> 装完 main 版 IPA 再拉。

### 8.4 分析
```bash
python3 tool/analyze_product_health.py <成品.wav> [<成品2.wav> ...]   # 纯 stdlib，无需 numpy
# 输出：① >=5ms 连续零采样断口（含前后 100ms 电平）② 长时平均频谱里 >12dB 的持续性窄带坑
#       ③ 11 个频段（300~20000Hz）的语音帧电平
/home/ycwork/.workbuddy/binaries/python/envs/default/bin/python tool/analyze_echo.py <成品.wav> <raw.pcm>
/home/ycwork/.workbuddy/binaries/python/envs/default/bin/python tool/analyze_spectrum.py <raw.pcm> <成品.pcm>
```
> 判读铁律：**间歇性陷波/抑制只能看 `_stats.log` 的 `notch=` / `lag=` / `rho=`**；
> 用「逐帧逐 bin 跟邻域比」找坑会有 ~50% 误报（语音谷被当成坑）。长时平均频谱
> 只用来判「**持续**」的坑。

## 九、已知真 Bug

1. **粘包/多 JSON 单帧**：`room_socket.dart` 的 `jsonDecode(data)` 一次只解一个对象。
   服务端若把 `leave`+`join` 塞进同一帧，`jsonDecode` 抛 `FormatException`，整帧
   两条消息都丢（现在有 try/catch，不再崩，但成员状态仍会错乱）。修法：先尝试
   整体解析，失败则按 `}{` 边界切分再逐条解析。**未修**。
2. ~~iOS 文件共享~~ **已修**：`Info.plist` 已加 `UIFileSharingEnabled` +
   `LSSupportsOpeningDocumentsInPlace`，`apps afc --documents` 可用（见 8.3）。

## 十、仓库当前状态

- **默认分支是 `main`（这个仓库没有 `master`）**。2026-11-13 已把第五轮修复合并到
  `main`，最新提交 `5c0d3da`（`fix(aec): 把 9k 陷波/诊断轨/底噪垫同步到 main`）。
- 另一条独立线 `test-bd2c408`（分支独有 `641c88a` → `cbaea64` → `62c5ca2` → `536d804`）
  与 main **结构不同**：那边相关门是 464 行精简版、上行不经过相关门；main 这边
  相关门是 725 行版（`rhoFull 0.28 / rhoNone 0.06 / doubleTalkGuard / refLacking`），
  且 **上行也要过相关门**（`upChunk = noiseGate.process(gated)`）。移植改动时不能
  照搬行号，要按语义落。
- main 近期脉络（新→旧）：
  `5c0d3da`(9k陷波/三件套诊断/底噪垫) → `efd6cb4`(UI 精简) →
  `cb87013`(恢复自搜门) → `9e324cd`(NLP 实验) → `0c91b1d`(门不回退) →
  `c7831aa`(回退到好基线) → `81f3c61`(文档) → `cc76ff0`(hardSync) →
  `30eddf2`(TRTC 机制) → `50178fc`(iOS 裸麦+门接上行)。
- 历史更早：`4ebc39f`(全频带) → `8ff23f7`(啸叫分平台延迟) → `ee95e43`(参考对齐+去削波)
  → `7832567`(实测页) → `7660e59`(AEC3 集成) → `9515f94`。
- 推送必须绕开本机坏代理（见第七节）。

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

## 十四、2026-11-12 第四轮：SYS_3A 双流回归 —— Android 成品空 / iOS 听到自己回声

### 现象（装机后真机录音）
- `handsfree_A_…_android.wav` 只有 0.08s、−77.8dBFS，几乎全空。
- iOS 端「一直听到自己的回声」。

### 根因（同一处改动：Android 双流）
1. **Android 成品空**：SYS_3A 在 Android 开的第二条 `VOICE_COMMUNICATION` 采集流，
   在 PMA120 上把第一条裸麦成品流**抢占停摆**。设备上 `成品.pcm` 与 `_raw.pcm`
   都只有 7680B（80ms）——`_raw` 是 worker 直接落 AEC 前采集，证明是**麦克风流本身**
   在第二流启动后断供，不是处理链问题。record 插件虽按实例隔离，但系统层并发采集
   会抢占（VOICE_COMMUNICATION 优先级高于裸 MIC）。
2. **iOS 听到自己回声**：成品流死了，但第二条上行流还活着往 iOS 送声；它挂在
   `modeNormal` 下，而 Android `AcousticEchoCanceler` 必须 `MODE_IN_COMMUNICATION`
   才生效 → 这条流的系统 AEC 实际没工作，把 iOS 的话经 Android 扬声器→麦原样送回，
   形成网络环路，iOS 听到自己的回声。**系统 AEC 本就追不上 ~1.1s 的网络环路**，
   治环路靠的是压增益（投票检测+双侧陷波+70%音量），不是系统 3A。

### 修复
- 新增 `kAndroidDualStream`（`--dart-define=SYS_3A_DUAL`，**默认 false**）：Android
  回到**单流**——裸麦 48k 一条流喂成品 + worker AEC3 上行（音质已验收的通路）。
  第二条流代码保留，仅在确认可并发采集的机型上显式打开做 A/B。
- **iOS 不变**（仍 VPIO 单流，无并发冲突）；iOS 回声是「经 Android 的网络环路」，
  Android 上行恢复 AEC3 后即断环，故 iOS 无需重新出包。
- 上一轮压环路增益的改进**全部保留**：投票检测、双侧陷波、70% 音量、成品底噪门。

### 验证
- `dart analyze lib/demo/aec3_room/` 全绿；`_sysUplinkActive` 仅在 `_startSysUplink`
  置真，而后者已被 `kAndroidDualStream`（默认关）挡住 → Android 默认走 worker 上行。
- **真机自证（adb 驱动进房开录）**：状态卡「系统3A上行」=「单流 · 裸麦48k→AEC3 上行」；
  录制持续 58s 不断流，导出 wav 58.1s / RMS −35.6dBFS / peak 0.893，>16kHz 能量非零
  （全频带通路完好）。对照修复前同机只有 0.08s / −77.8dBFS 空文件。

### 出包 / 装机
- Android：`flutter build apk --debug --dart-define=ROOM_TEST=true
  --dart-define=ROOM_ID=aec3test --dart-define=KEEP_RAW=true`，adb 重装。
- iOS：沿用已装 IPA（VPIO 开），本轮未改 iOS 音频行为，不出新包。

### 真机复测要点（本轮）
1. Android 状态卡「系统3A上行」应显示「**单流 · 裸麦48k→AEC3 上行**」；成品 wav 应
   正常有声、20kHz 全频带（不再是 0.08s 空文件）。
2. iOS 不应再听到自己的回声（Android 上行已重新经 AEC3 消回声）。若仍有，先确认
   Android 状态卡残留门「对齐 xxx ms」是否正常，再考虑 `SYS_3A=false` 关 iOS VPIO A/B。
3. 啸叫：两端对话 30s+ 不应再金属尖叫；守卫「已触发 N 次」与陷波锁频仍应 5s 内生效。

## 十五、第十五轮：iOS 音质回退裸麦 + 相关门按实测重调 + 门接上行（2026-11-12 晚）

### 用户反馈
iOS 仍能明确听到自己的回声；Android 成品录到两个人的声音；iOS 成品频谱不到
16kHz（应 20kHz）、底噪"太干净"不自然。用户点名 bd2c408 之前的 iOS 音质是好的。

### 根因（全部有离线数据支撑，成品在 ~/Downloads/audio/test 18:27 那组）
1. **iOS 音质** = bd2c408 引入的 VPIO（voiceChat + echoCancel/NS/AGC）：
   成品大段 -240dBFS 数字零底噪、带宽被限；且播放走 FlutterPcmSound 自己的
   AudioUnit，VPIO 的 AEC 根本参考不到这条渲染流——音质毁了，回声也没消掉。
2. **Android 成品双人声** = 相关门阈值卡错：用当天录音实测，纯回声帧的 10ms
   波形 rho 中位数只有 0.36~0.43（opus+扬声器非线性+混响吃掉相关性），
   rhoFull=0.40 正好卡在分布中位数上 → 一半回声帧只落到过渡区（-12dB），
   对方声音清晰可辨。离线对比成品/raw：门确实间歇生效（个别段 -18~-34dB）。
3. **iOS 听到自己回声** = 门只接在成品链路，上行不过门：AEC3 消不掉的残余
   被原样回传。另实测**网络单向延迟高达 2~3.6s**（iOS 语音 3.03s 后才出现在
   Android 采集里，往返 ~7.6s）——这是服务端问题，任何按小延迟设计的 AEC
   （包括 TRTC 引擎，其前提是单向 <400ms）都追不上；但相关门用**本地播放
   参考**判决，不受网络延迟影响，是唯一可行的 app 侧手段。
4. **门锁不稳的次生 bug（离线仿真暴露）**：a) 静音帧捷径把 `_lag` 提前赋成
   假设值 300，永久废掉冷启动长探针（代码注释里自己警告过的坑）；b) 40ms
   短探针在近端主导时随机峰也能过 0.05 门槛，lag 每 100ms 乱跳（仿真轨迹
   300→468→788→49…）。

### 改动
- `handsfree_room_page.dart`：`kSys3A` 默认 **false**（iOS 回裸麦 48k，成品恢复
  20kHz 全频带+自然噪底；VPIO 仅 `--dart-define=SYS_3A=true` 做 A/B）。
  状态卡「系统3A上行」默认显示「关 · 裸麦48k→AEC3+相关门 上行」且判 ok。
- `residual_gate.dart`：
  - 阈值按实测重调：rhoFull 0.40→**0.28**、rhoNone 0.10→**0.06**、过渡区
    midFloor 0.25→**0.10**（-20dB）；maxDelayMs 620→1200（覆盖播放缓冲漂移）。
  - 删掉静音帧对 `_lag` 的提前赋值（冷启动长探针不再被废）。
  - 搜索改两遍：40ms 短探针快筛候选 → **200ms 长探针复核**（随机相关 ~0.05，
    真对齐 0.3~0.5），接受门槛 fineAccept=0.20 + 切换滞回 fineHyst=0.08，
    当前锁定位永远参与复核。冷探针 600→1000ms，环 2s/3s，topK 3→4，
    搜索门槛放宽为 minLag+探针（开局 ~1s 即可锁定）。
  - 判决加 ±2.5/±5ms 五个偏移取最大 rho（缓冲漂移容差）。
- `audio_processing_worker.dart`：**上行与成品共用门的判决**（一次 process，
  两条链路各过独立底噪门）。上行过门 = 远端残余不再回传 → iOS 不再听到自己，
  且网络环路对啸叫常闭。代价：双讲时上行被部分压低（网络延迟已是秒级、
  对话本就轮流说，成品干净优先）。
- 新增 `tool/gate_offline.dart`：用真机 raw + 对端成品离线回放门的判决路径
  （`dart run tool/gate_offline.dart <capture.pcm> <farend.wav> [echo_lag] [ref_lead]`）。

### 离线验证（真机 18:27 数据）
- 纯回声段压制 **25.9dB / 11.2~25.9dB**（修复前同数据 10.6dB，线上听感漏声）；
  纯本端段 **0.0dB**（硬保护完好）；混合段 4.0dB（双讲轻压，符合取舍）。
- `dart analyze lib/demo/aec3_room/ tool/`：新增/改动文件 0 issue。

### 出包 / 装机
- Android：`flutter build apk --debug --dart-define=ROOM_TEST=true
  --dart-define=ROOM_ID=aec3test --dart-define=KEEP_RAW=true`，adb 重装。
- iOS：触发 `.github/workflows/ios-release.yml`（workflow_dispatch）出新 IPA 重装
  ——本轮 iOS 行为变化大（VPIO 关），必须重装。

### 真机复测要点（本轮）
1. iOS 成品：频谱应回到 ~20kHz、底噪自然（不再有 -240dBFS 数字零段）。
2. Android 成品：对端说话、本端静默的段落应接近静音（≥20dB 压制）；
   状态卡「残留门」应显示「对齐 xx ms（ρ=…）」且 ρ 随对端说话上升。
3. iOS 不再听到自己的回声（Android 上行已过门）；双讲时上行会被压，属预期。
4. 服务端单向延迟 2~3.6s 明显异常（TRTC 同级场景 <400ms），建议查
   appapi.zhiyuexc.com/audiowss 的混音/转发缓冲——这不修，对话体验始终差。

## 十六、TRTC 闭源包解剖 + 成熟厂商方案对比 → 稳定版设计（2026-11-12 晚）

### TRTC 闭源包能不能看？——能，部分能
iOS 的 `TXLiteAVSDK_Professional.xcframework` 不在本地（podspec 远程拉），
但 **Android AAR 在 gradle 缓存里**：`LiteAVSDK_Professional-13.6.0.20747.aar`
→ `/tmp/liteav/jni/arm64-v8a/libliteavsdk.so`（15MB）。对它做 `strings`
拿到了 TRTC 内部 3A 的**架构级事实**（不是猜的，全是它自己的日志/符号/云控 key）：

**TRTC 的回声链路（从二进制里读出来的）：**
1. **两级 AEC**：AI-AEC（`aiec/` 目录，多个模型：60m/80m/95m/105m/140m，
   MDF/SMDF/AMDF 多种自适应滤波结构）为主，**推理失败自动降级到经典 AEC**
   （`AiEcDownGradeToClassicAec` / `"aiec down grade to classic aec"` /
   `"downgrade to classic 3a … inference error count"`）。经典核就是
   **WebRTC AECM**（`aecmaec_aecmcore.c` / `Aecm_aec.c` / `iAecm_clean_farend`）。
   → 和我们一样：AEC3(线性) + 一层非线性残余抑制，只是它上层用 NN。
2. **NLP 残余抑制分级可调**：`aec_nlp_level`（云控 `force_nlp_level`），
   这就是它的"残留门"——对应我们的 correlation gate。
3. **延迟估计/补偿是独立开关**：`aec delay estimate switch` /
   `aec delay compensate switch` / `TapAecAnsCore_SetDelayChangedState` /
   `TapAecAnsCore_SetDelayJitterState` / `update echo delay` /
   `AEC_filter_reset1:last_delay=%d,delay=%d`。→ 印证：**参考↔采集延迟对齐
   是 AEC 成败的第一要素**，TRTC 专门有延迟抖动状态机。我们靠
   `_forwardReference`(ref 延迟 `_refDelayMs`) + 门的 lag 搜索做同一件事。
4. **收敛期静音**：`convergence_mute_enable` / `aec_beginning_mute_time_ms` /
   `aec_beginning_mute_config`。→ AEC 没收敛前先静音，避免漏回声。
   **这一条我们还没做**（见稳定版）。
5. **参考饥饿处理**：`"aec data feed playout lack"` / recover、`EchoBus`、
   `AecStereoReferencePcmStrategy`。→ 渲染流断供时专门处理，对应我们
   `_aecStarved`（缺参考计数）。
6. **独立啸叫处理器**：`AudioHowlingProcessor`（`kHowlingProcess`）、
   NN 模型 `grulite_howling_16k.bin` / `trae_howling_grulite16k`、
   `enableHowlingDetect` / `enableHowlingSuppression` /
   `"mic howling happened!! sr:%f,delay:%f"`、告警码 7002
   `WARNING_MICROPHONE_HOWLING_DETECTED`。→ 啸叫是**独立一级**，用 GRU 网络。
   我们用 `HowlNotch`(陷波) + `LoopGainGuard`(环路增益 duck)，是它的轻量版。
7. **回声状态检测灵敏度可调**：`echo_state_detect_sensitivity=60`。
8. **AI 降噪也是分级 + 降级**：`AINS`(`ains_dccrn`/`ains_percepnet`)、
   `force_ans_level`、`enable_ains_weak_suppress`、`adaptive_ans_mode`、
   `ans_version`。→ 对应我们的底噪门，但它是 NN 且分强弱档。
9. **AGC**：`ebur128`（广播响度标准）+ `force_agc_level`。**我们没做 AGC**。

**TRTC 原生头文件补充事实**（`TRTC_Flutter-master/windows/include/TRTC/*.h`）：
- `ITXDeviceManager.h`：**通话音量**类型有系统 AEC；**媒体音量**类型用不了系统 AEC。
- `ITRTCCloud.h:1124`：开**自定义采集**可能关掉 SDK 的 AEC（时序控制要求）。
- `TRTCCloudCallback.h:977+`：`onCapturedAudioFrame` 交付的是**已过 3A(ANS/AEC/AGC)** 的 PCM。
- 音质档：Speech 18k / Default 50k / Music 128kbps 全频带立体声。

### 成熟厂商的共识（Agora / AliRTC / anyRTC / 网易云信，公开资料）
- **iOS**：因苹果软硬件高度定制，**系统 VPIO 的 AEC 效果有保证**，首选硬件 AEC
  （VOICE_COMMUNICATION / voiceChat）；**Android 碎片化**，系统 AEC 参差甚至没有，
  **必须加应用级软件 AEC 兜底**（zego 技术分享原话）。
  → ⚠️ 这正是我们 iOS 的两难：VPIO 效果好，但**它参考不到 FlutterPcmSound
  那条独立 AudioUnit 渲染流**（我们不走系统通话播放路由），所以 VPIO 的 AEC
  拿不到参考 = 白开，还毁了音质（限带 + 数字零底噪）。TRTC 不会有这问题，
  因为它**自己拥有整条播放路由**（`SpeakerphonePlayoutTrack`），渲染字节和
  AEC 参考天然同源。
- **完整 AEC 四件套**（anyRTC/阿里云）：时延估计(TDE) → 线性 AEC(NLMS/频域)
  → 双讲检测(DTD) → **非线性残余抑制(RAES/NLP)**。我们的链 = AEC3(TDE+线性)
  + correlation gate(RAES)，DTD 隐含在门的 rho 判决里。
- **NN 残余抑制是趋势**：DFSMN / GCCRN / ICCRN 后滤波器级联在线性 AEC 之后
  （知乎 Multi-task Deep RES；TRTC 的 `aiec_*` 就是这类）。**这是我们能借鉴的
  下一代方向，但需要模型 + 训练数据，本轮不做。**

### 对比结论：我们现在的链 vs TRTC/成熟方案
| 环节 | TRTC | Agora/Ali | 我们现状 | 差距 |
|---|---|---|---|---|
| 线性 AEC | AI-AEC(MDF/SMDF)+AECM 降级 | WebRTC AEC/AECM | **WebRTC AEC3** | 同级（AEC3 就是经典核） |
| 残余抑制 NLP | aec_nlp_level 分级 | RAES | **correlation gate** | 同级（我们是相关性门，它是能量/NLP 门） |
| 延迟对齐 | delay estimate/compensate 状态机 | TDE | **ref 延迟 + 门 lag 两遍搜索** | 同级 |
| 参考饥饿 | playout lack/recover + EchoBus | — | **_aecStarved 计数** | 同级 |
| 啸叫 | 独立 AudioHowlingProcessor(GRU NN) | — | **HowlNotch + LoopGainGuard** | 我们轻量版（无 NN） |
| 降噪 | AINS(dccrn/percepnet) 分级 | AI 降噪 | **底噪门(noiseGate)** | 我们简单门限（无 NN） |
| **收敛期静音** | **convergence_mute / beginning_mute** | — | **❌ 没有** | **建议补** |
| **AGC** | **ebur128 + force_agc_level** | 有 | **❌ 没有** | 可选补 |
| iOS 硬件 AEC | 拥有播放路由，VPIO 参考同源 | 首选 VPIO | **VPIO 参考不到我们的渲染流 → 关闭** | **架构差异，非 bug** |

**一句话**：我们的软件链在"线性 AEC + 残余抑制 + 延迟对齐 + 啸叫 + 参考饥饿"
上和 TRTC **同构、同级**，差的是 (a) NN 化的残余抑制/降噪/啸叫（需模型，本轮不做）、
(b) **收敛期静音**（易补，收益大）、(c) AGC（可选）。iOS 音质问题的根不是算法弱，
而是**播放不走系统通话路由 → VPIO 拿不到参考**，这是架构取舍，TRTC 靠自有播放路由规避。

### 稳定版设计（建议落地顺序）
**Tier 0（本轮已做，待真机验收）**：kSys3A 默认关（iOS 裸麦 48k 全频带）
+ 门阈值按实测重调 + 两遍 lag 搜索 + **门接上行**（断网络自回声环路）。

**Tier 1（低风险、马上可补，直接抄 TRTC）**：
1. **收敛期静音**：进房后 AEC3 未收敛的前 `N ms`（TRTC 用
   `aec_beginning_mute_time_ms`，经验 300~500ms）上行直接静音或强压，
   避免冷启动漏回声。我们的门已有 `_aecStarved`/冷启动计数，接一个
   `_converged` 标志即可（AEC3 首次成功对齐 lag → 置位）。
2. **参考饥饿显式化**：`_aecStarved` 超阈值时，上行按能量兜底压低
   （TRTC 的 playout lack/recover 语义），别让 AEC 拿不到参考时裸传。

> **✅ Tier 1 已实现（2026-11-12 晚）**：
> - `residual_gate.dart`：新增收敛期静音。`convergeMuteMs=3000`（兜底上限）、
>   `convergeSettleFrames=20`（锁定后再稳 200ms 解除）。状态机：`_lag` 首次
>   锁定 → 记 `_lockFrame` → 稳 200ms → `_converged=true`；一直锁不上则到
>   3000ms 无条件解除（防全程哑掉）。**只在「下行在响」时压死整帧到 gFloor**
>   （`refRms>=1` 分支），下行静默仍走硬直通，绝不误压本端说话。
> - 参考饥饿：门的 `refRms<1 → g=1` 硬直通**已经覆盖**——参考断供/静默时
>   本就没有新回声（房间衰减 ~50-100ms），直通是安全的，无需额外代码。
> - `audio_processing_worker.dart`：`aec_stats` 增 `gateConverged` 上报。
> - `handsfree_room_page.dart`：残留门状态卡显示「收敛期静音中（压死冷启动
>   回声）」/「已对齐 xx ms，稳定中…」/「对齐 xx ms（ρ=…）」，`ok` 要求已收敛。
> - 离线仿真（`/tmp/a_raw.pcm` × iOS 18:27 成品，lag=3027/lead=2877）：
>   稳态压制 **25.9dB / 11.2dB 不变**、纯本端 **0.0dB**、混合 4.0dB —— 无回归；
>   lag 轨迹前 ~5s 仍在 `-1/17/766/1039…` 乱跳，收敛期静音正好把这段冷启动
>   漏声压死（旧行为这里会漏回声）。`dart analyze` 三文件 0 issue。

> **✅ 双讲保护（VAD + NLP 分级软压）也已实现（2026-11-12 晚，对标 TRTC
> `nearend unmute` / `aivad` / `aec_nlp_level`）**：
> - `residual_gate.dart`：新增轻量近端 VAD（不引 NN）。判据 = 采集电平高出
>   自适应噪底 `vadVoiceMarginDb=10dB` **且** `rho < vadRhoMax=0.15` **且** 非纯残余。
>   命中（双讲）→ 过渡区改软底 `midFloorVoice=0.5`(-6dB) 保留本端；纯回声帧
>   维持硬底 0.10 / 能量兜底 gFloor。开关 `doubleTalkGuard`（worker
>   `--dart-define=RESIDUAL_GATE_DTLK=false` 可关做 A/B）。
> - **关键调参教训**：单靠电平 VAD 分不清「响回声」与「响本端」——AEC3 消不净
>   的残余本身就很响，电平判据把 7% 纯回声帧误判成双讲，最强回声段从 25.9 掉到
>   24.1dB。叠加 **rho 上限 0.15**（双讲时本端稀释相关、rho 偏低 p50≈0.12；
>   纯回声 rho 偏高 p50≈0.36）后，纯回声误命中降到 1%、压制恢复 25.8dB。
>   这是 TRTC 与我们差距的体现：TRTC 的 AI-AEC 把回声消得差不多，残余≈本端，
>   电平 VAD 才够用；我们 AEC3 残余重，必须靠相关性兜底。
> - 离线 A/B（`/tmp/a_raw.pcm` × iOS 18:27 成品）：
>   | 段 | 关双讲保护 | 开（rho上限0.15）| 近端VAD命中 |
>   |---|---|---|---|
>   | 纯回声 43-46s | 25.9dB | **25.8dB** | 1% |
>   | 纯回声2 52-57s | 11.2dB | **11.2dB** | 20%（低rho帧，无害）|
>   | 纯本端 27-31s | 0.0dB | **0.0dB** | 0% |
>   | 混合 3-10s | 4.0dB | **4.0dB** | 29%（正确检出双讲）|
>   结论：**加双讲保护、回声零回归**；混合段压制未大降是因为该窗口前段被收敛期
>   静音主导、基线压制本就 mild，持续真实双讲下软压保留本端的效果会更明显。
> - `tool/gate_offline.dart` 增 A/B 与调参入口：`... [echo_lag] [ref_lead]
>   [dtlk=true/false] [vadMargin=10]`，并打印各段近端 VAD 命中率。
> - `dart analyze` 四文件 0 issue。


**Tier 2（服务端，收益最大）**：**修 `appapi.zhiyuexc.com/audiowss` 的
2~3.6s 单向延迟**。TRTC/Agora/Ali 全部前提单向 <400ms；延迟不修，任何按
小延迟设计的 AEC 都追不上，我们只能靠本地播放参考的门兜底——门的压制上限
就是对话体验的天花板。这是**当前最高优先级的外部依赖**。

**Tier 3（下一代，需资源）**：NN 残余抑制（GCCRN/ICCRN 后滤波器）替换/叠加
correlation gate，NN 啸叫抑制（对标 `grulite_howling`）。需要模型 + 训练数据，
非本轮范围。

**结论**：Tier 0（已做）+ Tier 1（收敛期静音，**已实现并离线验证无回归**）就是
**当前可交付的稳定版**；Tier 2 是服务端必须跟进的前提；Tier 3 记为路线图。
待真机在线后按第十五/十六节复测要点验收即可。

## 十七、TRTC 怎么播放 + 是否要把 FlutterPcmSound 换成 TRTC（2026-11-12 晚）

### TRTC 的播放路线（闭源包 strings + 头文件实证）
TRTC **自己拥有整条渲染链路**，不是把 PCM 丢给系统播放器：
- **Android = AAudio**：`AAudioPlayer`/`AAudioRecorder`、`AAudioStreamBuilder_
  setSessionId`/`setSharingMode`、`aaudio.mmap_exclusive_policy`、
  `aaudio_performance_mode`。mmap 独占 + 低延迟性能模式，采集与播放共用
  session，时钟同源。
- **播放轨直接喂 AEC 参考**（reference co-source）：`Add audio playout track
  when audio playout started`、`aec data feed playout lack/recover`、
  `current diff between capture and playout is: %d, capture count … playout
  count …`、`AecStereoReferencePcmStrategy`。播放线程产出的 PCM **就是** AEC
  的参考，采集/播放样本数差被实时跟踪对齐。
- **自定义渲染**：`enableCustomAudioRendering(true)` +
  `getCustomAudioRenderingFrame(TRTCAudioFrame*)`，头文件明确「**建议由系统的
  音频播放线程直接驱动该函数的调用**，播放完一帧即取下一帧」。即渲染节拍由
  系统音频时钟驱动，不是 Dart/UI 定时器。
- **外部参考兜底**：`appendExternalReferencePCM` /
  `AppendExternalReferencePCMSync` —— 当参考不是自家播放轨时，把外部 PCM 显式
  灌进 AEC 当参考。`setLowLatencyModeEnabled` 进一步压渲染延迟。

一句话：**TRTC 播放的核心价值 = 参考与扬声器字节同源 + 系统音频时钟驱动对齐**，
而不是「播放器本身音质更好」。

### 我们现在的播放路线（已实证）
`AudioPlaybackManager` → `flutter_pcm_sound`（独立 AudioUnit/AAudio 流，**与
采集不是同一个**）。但关键的一步我们已经做了：
- `audio_playback_manager.dart:207` `_doFeed` 在喂扬声器**之前**，把**同一份**
  已过 volume/duck/fade 的字节经 `onPlaybackReference` 交出去；
- → `handsfree_room_page.dart:462 _forwardReference` → worker `ref_chunk`
  → `audio_processing_worker.dart:389/391` **同时** `aec.pushReference` +
  `gate.pushReference`。

这正是 TRTC `appendExternalReferencePCM` 那条路的**应用层等价实现**：参考与
扬声器字节同源。门的延迟搜索因此只需追**播放缓冲**（~100ms），与网络延迟无关。

### 是否替换：结论 = **不必整体换**
| 维度 | 换 TRTC 播放 | 维持 FlutterPcmSound + 本地参考 |
|---|---|---|
| 参考同源 | 引擎级原生 | **已用 onPlaybackReference 达成等价** |
| 时钟对齐 | 系统音频线程驱动，最紧 | Dart 5ms 泵 + 门两段式 lag 搜索（±240/±120/0）吸收抖动 |
| 代价 | 引入**整个 SDK/引擎**（非单播放器）、license、包体、与自研 AEC3+门链路冲突 | 0 |
| 成品音质 | TRTC NS/AGC 改频响，与「48k 全带 + 自然底噪」目标冲突 | 保留已调好的全带链路 |

- **参考对齐这个真问题已经解决**：iOS 之前回声的根因是 VPIO 无法引用
  FlutterPcmSound 的独立 AudioUnit（双重损失），我们已**回退裸麦 + WebRTC AEC3
  + 自喂参考**绕过，不再依赖 VPIO。换 TRTC 能「根治」的正是这一点，但我们已经
  用应用层参考同源把它绕过去了。
- **唯一真实差距**是时钟对齐精度（系统线程驱动 vs Dart 泵）。但门的动态 lag
  搜索就是为吸收这种抖动设计的，离线实测稳态压制 25.8dB 已达标，边际收益小。
- **换 = 丢掉已调好的链路 + 背上整个 SDK**，成本远大于收益。

**建议**：不换播放器。把 TRTC 值得抄的**机制**（收敛期静音、VAD/NLP 双讲分级
软压、参考同源）抄进自研链路即可——这些**已全部实现并离线验证**。播放路线维持
现状。若未来真机实测发现 Dart 泵抖动导致 lag 频繁失锁，再考虑「系统音频线程
驱动参考」的局部改造（仍不必引入 TRTC SDK）。

## 十八、TRTC 音频栈全量盘点 + AI AEC 是什么 + 本轮抄回（2026-11-12 晚）

> 方法：`strings` 全量扫 `libliteavsdk.so`（35560 条）+ 头文件，把 TRTC 音频
> 处理栈彻底盘了一遍，逐条评估「能不能抄、值不值得抄」。

### 18.1 AI AEC（用户问的「ai ace」）到底是什么
TRTC 的 3A 早已不是纯传统 DSP，而是**一整套 ncnn 神经网络模型**（打包成
`.ncnn.liteavbin`/`.liteavparams` 塞在 .so 里，运行时 ncnn + litenn 推理）：

| 模块 | strings 实证 | 作用 |
|---|---|---|
| **AIEC**（AI 回声消除）| `aiec_60m_amdf`/`95m_amdf`/`95m_mdf`/`105m_mdf`/`80m_smdf`/`140m_mdf`、`dpgru_model_*`、`aec_level 120AI`、`is_enable_ai_ec_module`、`ai_ec_model_type` | 用 **DPGRU**（深度门控循环网络）做回声消除，替代/增强传统线性滤波器（AMDF）。`aec_level 120AI` 是 AI 档；模型无效时 `downgrade to 60` 优雅降级 |
| **ICCRN**（残余回声后滤波）| `iccrn_model_140m_mdf_32k`/`80m_mdf`/`80m_smdf` | 线性 AEC 之后的**神经残余回声抑制 + 降噪**，即传统 NLP 的 AI 替代 |
| **AINS**（AI 降噪）| `ains_dccrn`（深度复数卷积循环网络）、`ains_percepnet`（PercepNet，Opus/RNNoise 血统）、`adaptive_ans_mode`、`big stable noise detected. enable denoise` | 神经降噪；**自适应**——只在检出「大而稳的噪声」时才开，避免误伤人声 |
| **AIVAD**（AI 语音检测）| `aivad`/`aivad2`、`kEnableAIVad`、`TapAivadProcessor_Process` | 神经 VAD，驱动双讲判决（`nearend unmute`）与 3A 门控 |
| **grulite_howling** | `grulite_howling_16k.bin`、`trae_howling_grulite16k` | 神经啸叫抑制（GRU-lite）|
| **ai_music_detect** | `percepnet_music_detect`、`non_music_detected_session_count` | 区分音乐/语音，音乐时不激进降噪 |
| 其它 | `ai-dred`（深度冗余/丢包补偿）、`ai-uplink-bicubic`（上行超分）、`ai-voice-protection`、`ai-super-ns`、`snr_estimation`、`kws` | 丢包 concealment、上行 16k→48k 超分等 |

**为什么 AI AEC 是关键差距**：AI-AEC 把回声消得很干净 → **残余≈本端** → 单靠
电平 VAD 就能判双讲（TRTC 的做法）。我们用 WebRTC AEC3 **线性**滤波，外放场景
残余重（20~25dB 封顶），电平分不清「响回声」与「响本端」，所以必须叠加 **rho
相关性上限**兜底（见第十六节调参教训）。这就是我们与 TRTC 的本质差距。

**能不能抄 AI 模型？不能。** 这些是腾讯**专有训练权重**，ncnn 格式打包在 .so
内（加密 blob），无公开模型文件、无 ncnn 运行时、无训练数据，且本环境禁止装
第三方原生包。我们能抄的是**架构思想**（用传统 DSP 近似），不是模型本身。

### 18.2 TRTC 全部可参考机制 × 评估（能抄/已抄/不抄）

| TRTC 机制（strings 实证）| 类型 | 我们现状 | 评估 / 动作 |
|---|---|---|---|
| `aec_beginning_mute` / `convergence_mute` / `EC:mute data 1 second` | 传统 | ✅ 已抄（收敛期静音）| 第十六节 |
| `aec_nlp_level` / `nlp level` 分级 | 传统 | ✅ 已抄（rho 分级软压）| 第十六节 |
| `nearend unmute` / `aivad` 双讲 | 传统+AI | ✅ 已抄（电平+rho VAD）| 第十六节 |
| `appendExternalReferencePCM` 参考同源 | 传统 | ✅ 已等价（onPlaybackReference）| 第十七节 |
| **`aec data feed playout lack/recover`** 参考断流 | 传统 | ❌→✅ **本轮抄回** | 见 18.3 |
| `reset tap processor since too much diff between capture and playout` | 传统 | 部分（门 lag 搜索自带滞回/拒绝坏峰）| 我们采集/参考本就异步，cap-playout 样本差不适用；已用 lag 搜索健康度覆盖 |
| `reset linear filter because of delay change` | 传统 | 门每 100ms 重搜 + 滞回跟随 | hardSync 丢的是**未喂**字节，已喂音频的回声 lag 不变 → 不需要重置（已核实）|
| `reset linear filter because of divergence` | 传统 | — | **不抄**：无法可靠区分「AEC 发散」与「正常远端单讲」，门压制已覆盖后者，误触发反而打断对话 |
| 自适应 jitter buffer（`Increase/Decrease target cache … avg_jitter`、`speed rate` catch-up）| 传统 | 固定 100ms + 500ms hardSync 丢弃 | **暂缓**：变速 catch-up 与我们 AEC3 参考对齐冲突（变速=延迟持续漂移，正是我们当初删 1.25x 的原因）；根因是服务端 2~3.6s 延迟（Tier 2）。真机若见播放卡顿再评估「只调缓冲深度、不变速」的保守版 |
| `audio_io_watchdog` / `thread_watchdog` | 基础设施 | Dart isolate + 插件自带线程管理 | **不抄**：对单 isolate 链路边际收益小，记路线图 |
| `ebur128 agc`（LUFS 响度 AGC）| 传统 | AGC 默认关 | **不抄**：AGC 在啸叫回路里会把振荡托回稳态（见 worker kUpstreamAgc 注释）|
| `adaptive_ans_mode` / `big stable noise → denoise` | 传统+AI | NoiseGate（谷值追踪底噪门）| **不抄谱减 NS**：会改频响、伤「48k 全带 + 自然底噪」成品bar；我们的底噪门已是电平域自适应，够用 |
| `ai_music_detect` 音乐门控 NS | AI | NS 关 | 不适用（NS 未开）|
| `soundcard mode` / 外置声卡白名单 | 传统 | 手机内置麦/扬声器 | 不适用 |
| `tap_delay_estimate_mode` / `low power delay estimation` | 传统 | 门两段式 lag 搜索 | 已有自研等价，低功耗模式边际 |
| `smart_3a_strategy_flag` 3A 编排 | 传统 | 静态 dart-define 开关 | 可未来做自适应编排，本轮不必要 |

### 18.3 本轮抄回：参考断流守卫（playout lack/recover）
**问题（真 bug，非假想）**：播放会停顿（网络断层 / 无新包）。停顿时参考环
**冻结**在最后一次播放的陈旧远端字节上，已无新回声产生。但门的**能量兜底**
（`本端电平 < 参考 - 14dB → 判纯残余硬压`）仍拿这份陈旧参考判决 —— 停顿期
本端说话（电平低于那段陈旧远端 14dB 以上）会被**误判成残余整句压死**。

**修复**（`residual_gate.dart`，对标 TRTC `aec data feed playout lack/recover`）：
- 新增 `_framesSinceRef`：每处理一帧采集 +1，`pushReference` 时清零。
- 超过 `refLackFrames=40`（≈400ms，远大于正常喂参考间隔 ~50ms）即判**参考断流**
  `refLacking`，**停用能量兜底**，把判决交还 rho 路径——本端语音与陈旧远端
  不相关，rho 自然落回 rhoNone 以下直通。
- worker `aec_stats` 增 `gateRefLack` 上报；门 doc 增第 9 条。

**验证**（`tool/gate_reflack_test.dart`，自包含合成信号，不依赖真机录音）：
| 配置 | 停顿期本端输入 | 停顿期输出 | 压制 |
|---|---|---|---|
| 守卫关（refLackFrames=1e5）| -33.3dB | -67.3dB | **34.0dB（误杀）** |
| 守卫开（refLackFrames=40）| -33.3dB | -33.3dB | **0.0dB（保留）** |

→ 停顿期本端语音多保留 **33.9dB**。**正常连续喂参考时守卫是 no-op**（每 ~5 帧
清零，永不达 40），对既有稳态压制零回归（可证：`!refLacking` 恒真 →
`residualOnly` 表达式与改前逐字一致）。`dart analyze` 五文件 0 issue。

### 18.4 稳定性结论
- **已抄回并验证**：收敛期静音、NLP 分级软压、双讲 VAD、参考同源、**参考断流
  守卫**（本轮）。这些是 TRTC 传统 DSP 层「值得抄」的全部，已落地。
- **抄不了**：AI 模型栈（AIEC/ICCRN/AINS/AIVAD/grulite-howling/music-detect/
  dred/bicubic）——专有 ncnn 权重，无运行时/无数据/禁装原生包。这是与 TRTC 的
  **代差**，只能靠传统 DSP + 相关性兜底逼近。
- **暂缓/不抄**：自适应 jitter buffer（变速与 AEC 参考冲突，根因在服务端延迟）、
  发散重置（无法可靠判别）、AGC/谱减 NS（违背成品 bar 或在啸叫回路里）、watchdog
  （边际）。均有明确理由，非遗漏。
- **最高优先级仍是 Tier 2**：服务端 `appapi.zhiyuexc.com/audiowss` 单向 2~3.6s
  延迟。它不修，播放侧任何缓冲策略都是band-aid，门的压制上限就是对话天花板。
- 待真机在线：重建带本轮改动的 APK/IPA，按十五/十六节复测，并**新增一项**——
  制造播放停顿（弱网）观察停顿期本端是否还被误压（验证 18.3）。

## 十九、播放器积压兜底复审（去掉变速后，2026-11-12 晚）

> 背景：变速播放（1.25x catch-up）已删（变速=延迟持续漂移，AEC3 永远在重收敛）。
> 复审剩下的积压兜底是否够稳、会不会播放「很久之前的音频块」。

### 19.1 延迟有界性（确认：不会无界积压）
`flutter_pcm_sound` **无 flush/clear/stop API**（实测 3.3.3 只有 setup/feed/
setFeedThreshold/setFeedCallback/start/release），native 缓冲清不掉。但延迟仍严格有界：
- **native 缓冲**：`_doFeed` 只在 native < `targetNativeMs=100ms` 时补到 100ms，
  feed 阈值 50ms → native 恒在 50~100ms oscillate，**上限 ~100ms（不可压缩下限）**。
- **Dart 缓冲**：每来一包先查 `totalBacklogFrames`（native 余量 + Dart 帧），
  超过 `hardSyncThresholdMs=500ms` 即 `hardSync()` 清空 Dart 缓冲。逐包检查 →
  Dart 缓冲最多 500ms+1包，**绝不无界增长**。
- **结论**：播放侧总延迟恒 ≤ ~600ms（500 Dart + 100 native）。服务端 2~3.6s
  单向延迟是另一回事（音频到达时就那么旧），播放侧保证**不再额外叠加 >600ms**，
  不会播放很久之前的块。

### 19.2 抗抖动 / 防欠载（确认：稳定播放）
- Dart 缓冲就是抖动垫：停包后 feed 回调（native<50ms 触发）持续把 Dart 喂进
  native，直到 Dart 空 → **可吸收 ~500ms 的包间隔**，欠载（卡顿）只在 >500ms
  断流时发生（opus 20ms/包，等于严重断网）。
- 断网 >800ms 重启有 10ms 渐入；hardSync 后也有 10ms 渐入，避免不连续咔嗒。
- `_nativeRemainingFrames` 乐观自增（_doFeed）会被回调 authoritative 值校正，
  过估窗口 <50ms 且偏保守（只会略早 hardSync），不会导致欠载。

### 19.3 本轮改进（已实现 + dart analyze 0 issue）
1. **hardSync 不再丢当前最新包**：旧行为 `hardSync(); return;` 把触发清缓冲的
   那一包（**最新到**的音频）也丢了。改为清完陈旧缓冲后**保留当前包**重建缓冲，
   少损失一帧（20ms）最 live 的声音。`handleIncomingOpusPacket` 与 `handleRawPcm`
   两条入口同改。
2. **丢弃量诊断日志**：`hardSync` 打印「丢弃陈旧缓冲 xxms / native 余 xxms」，
   真机据此判断丢弃是否过频（过频=服务端在猛灌 burst）。
3. **延迟上限写进常量注释**：`hardSyncThresholdMs` 注明 ~600ms 硬上限与调参方向。

### 19.4 评估过但**不改**的
- **自适应 jitter buffer（TRTC jitter v2）**：靠变速 catch-up，与我们 AEC3 参考
  对齐冲突（变速=延迟漂移），且根因是服务端延迟。维持「固定 500ms 上限 + 丢弃」。
- **调小/调大阈值**：100ms native（不可 flush 的下限）+ 500ms 总上限已是
  「贴近 live」与「抗抖动」的折中；服务端延迟主导，再调边际无感。
- **trim 保留部分旧缓冲**：与「只播最新」目标相悖（清全部 = 只留最新，最优）。

## 二十、2026-11-13 第五轮：成品「频谱断裂」= 门链串联成 −53dB 数字静音（已修）

> 这一节是**换地方开发后最先要读的**：解释了为什么之前的成品会出现大片「断掉」
> 的段落，以及为什么不要再用「逐帧频谱挖坑」那套指标下结论。

### 20.1 用户反馈与本轮目标
- 前一轮反馈是「有杂音，也有回音」；装 `641c88a`（双流诊断线）后变成
  **「出现了频谱断裂情况了，数据也不行」** —— 听感是句子中间突然静音，像信号丢了。
- 本轮只做一件事：**把断裂的真实根因量化并修掉，不做任何阈值玄学**。

### 20.2 量化证据（真机成品，不是推测）
分析对象：`~/Downloads/audio/test/handsfree_A_20261113_162048_android .wav`
（48.56s，注意文件名末尾有个空格）与 `handsfree_B_20261113_162051(1).wav`（45.00s）。

| 指标 | A（断裂） | B（正常） |
|---|---|---|
| ≥5ms 连续零采样段 | **32 段，合计 0.77s** | **0 段** |
| 主断口位置 | 7.009–7.36s、12.076–12.25s | — |
| 断口前后电平 | −54 → −70 → −83 → −99 → **−113dBFS**，平滑指数衰减，然后突然恢复 | — |
| 持续性窄带坑（长时平均频谱 −12dB） | 无（最大单 bin 偏差 19.5%，全是语音谷） | 无 |
| 8kHz 分界带 | 7750/8000/8250Hz = 33/32/33dB，连续 | 35/34/37dB，连续 |
| 10~20kHz | 频段电平平滑过渡，无缺失 | 同 |

**排除**：不是陷波挖坑、不是 8k 分带断裂、不是高频旁路缺失。断口的形状
（平滑衰减到底再突然恢复）是**数字静音**，不是滤波。

### 20.3 根因（纯算术，可复核）
成品链下游串联了两个门，最坏情况增益相乘：

```
ResidualGate.gFloor = 0.02   → −34.0dB
NoiseGate.minGain   = 0.11   → −19.0dB
合计                         → −53.0dB
```

安静期房间底噪实测 ≈ **18 LSB**（约 −65dBFS）。18 × 0.02 × 0.11 = **0.0396 LSB**
→ int16 取整 **= 0**。整帧全是 0，就是听到的「断裂」。
只要两门同时压在底（远端静音 + 本端静音的交界处最容易同时发生），
就会连续输出零采样；B 端房间更吵（底噪更高）所以从未触发。

### 20.4 修复：底噪垫 `comfort_noise.dart`（只补差额，不新开一层门）
设计原则：**成品允许有自然底噪，但绝不允许是数字零**。

- 目标电平：`target = 锚点 − 19dB`，夹在 `[−84, −60] dBFS`。
  −19dB 恰好等于底噪门在静音帧留下的增益，听感与「门正常工作时的安静期」一致。
- 锚点：**门之前**那帧的 RMS（`frameDbfs(chunk)`），自己用最小值跟踪器：
  瞬时下降、每帧最多 +0.002dB（≈0.2dB/s）上升。这样语音段不会把锚点抬走，
  也不会被下沉的门电平拖低。
- 只在 `curRms < targetRms` 时补：`needRms = sqrt(target² − cur²)`，
  均匀白噪 × `√3` 折算幅度，逐样本加到原信号上。**不衰减原信号**，所以不会
  再引入第二层乘法。
- 只作用于**成品路径**（下行给对方/落盘的 outChunk），**上行永不垫**（否则把
  噪声发给对端）。
- 开关：`--dart-define=COMFORT_NOISE=false` 可复现旧行为做 A/B。

### 20.5 离线验证（合成 + 真机数据回放）
- 把 A 的断口段（−54 → −113dBFS）回放进新链：输出最低 **−84.2dBFS**，
  **零采样段 = 0**；安静期电平分布为 −84/−84/−83dBFS（p10/p50/p90），
  与「门正常工作的安静期」一致。
- `dart analyze` 0 issue。
- 反向确认：`COMFORT_NOISE=false` 时断口原样复现 → 证明是这一层在兜。

### 20.6 同步到 main + 分支处置
- 仓库**没有 `master`**，默认分支是 `main`。本轮把修复移植到 main（不能照搬
  行号：main 的上行也过相关门，见第十节），提交 **`5c0d3da`**。
- `test-bd2c408` 分支保留原样（双流诊断线），**不要**在它上面继续开发。
- 移植时同时落了：陷波上限 4.0k → **9.0k**（`loop_gain_guard.highBin 192`，
  真机宽带回环实测落在 5.4k / 7.9kHz）、`_ref.pcm` 参考轨、`_stats.log` 每秒统计。

### 20.7 新增诊断三件套（KEEP_RAW=true）
| 文件 | 用途 |
|---|---|
| `_raw.pcm` | AEC 前采集 → 算真实 ERLE、找回声延迟 |
| `_ref.pcm` | AEC 实际吃到的参考（播放缓冲那份）→ 与 raw 互相关定位回声 |
| `_stats.log` | 每秒 `t= in= out= lag= rho= floor= notch= vote= peak= duck= frames= starved=` |

判读要点：
- `starved%` 高 = 参考断供（采集/播放两时钟不锁定），AEC 再准也没用；
- `lag` 应≈真实回声延迟（真机实测 321~352ms），`rho` 在远端单讲时应明显升高；
- `out−in` 近似 ERLE；`notch=` 是页面检出的啸叫频点（间歇性证据只能看这里）。

### 20.8 出包 / 装机状态
- Android：`main@5c0d3da` **profile** 包（KEEP_RAW=true）已装到 PMA120。
- iOS：CI run `43398328280` 成功，IPA 在 `/tmp/ios_ipa_5c0d3da/my_flutter_app.ipa`；
  当时 iPhone 未连（`usbmuxd` 未起），**尚未安装** —— 接手后第一件事就是装上。

### 20.9 仍未解决（别以为修完了）
1. **「回音」没有被证实**：A/B 两条成品里都检测不到远端语音包络
   （包络互相关 0.05），说明成品大概率没有对方声音；用户听到的回音更可能是
   **本地扬声器→麦克风当场听到的**，或者是服务端 2~3.6s 延迟造成的「答非所问」。
   要定论必须拉 `_raw.pcm` / `_ref.pcm` 算 ERLE 与延迟。
2. **服务端 `audiowss` 单向 2~3.6s 延迟**仍是天花板（Tier 2），App 侧只能兜底。
3. 底噪垫的量（−19dB / 下限 −84dBFS）只做了离线与单次真机验证，需要
   `COMFORT_NOISE` A/B 两条真机录音做最终听感确认。

### 20.10 工具：`tool/analyze_product_health.py`（纯 stdlib）
```bash
python3 tool/analyze_product_health.py 成品1.wav 成品2.wav
```
输出三块：
1. **≥5ms 连续零采样断口**（本轮问题的直接判据），附断口前后 100ms 电平；
2. **长时平均频谱的持续性窄带坑**：以 ±300Hz 平滑谱为参考，中心 ±3 bin 排除，
   低于参考 12dB 才报；**不报间歇性陷波**（那只能看 `_stats.log`）；
3. 11 个频段（300~20000Hz）的语音帧电平。
> 反面教材：曾用「逐帧逐 bin 与邻域比」找坑，在 7.7~8.2kHz 产生 45~59% 误报，
> 高点名了一个**根本不存在**的 8k 坑（细谱实测 8000Hz 处只低 1~3dB）。
> 判「有没有坑」一律用长时平均谱 + `_stats.log` 双证据。
