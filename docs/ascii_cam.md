# ASCII 实时头像（ascii_cam.py）— 使用与上真机步骤

这台 Windows PC 的摄像头拍人 → 每帧渲成绿屏 ASCII 数码头像 → UDP 推到 AgentZero 内核屏幕实时显示。
摄像头、人脸跟踪、字符映射都在这台 PC 做（`--kernel-render` 模式除外），老 PC 只存文本格并重绘。

## 1. 管线与指令

```
摄像头 640x480 → mediapipe 人脸关键点(每2帧) → EMA+死区平滑的 4:3 裁剪框 → 灰度
→ CLAHE 局部对比度 → 时间 EMA（去闪烁）→ ascii_art.render（自动对比度 + 短 ramp " .:-=+*#%@"）
→ 三档亮度（ramp 0-3 暗绿 / 4-6 亮绿 / 7-9 白）→ UDP 块写
```

内核新增（本次 commit，pxe_cam.img）：

| 指令 | 作用 |
|---|---|
| `b<2hex 起始行>\n行\n行…` | 块写但**不重绘**（一帧的前几包） |
| `B…`（原有） | 块写并重绘（一帧最后一包 → 整帧一次上屏，无撕裂） |
| 行内字节 `0x01/0x02/0x03` | 之后的格子用 暗绿 0x02 / 亮绿 0x0A / 白 0x0F 属性；块结束恢复默认绿（聊天文字不受影响） |
| `g<2hex 行><1hex 重绘>` + 原始灰度字节（每行 80 字节） | **老 PC 自己转换**：内核 CPU 把每个亮度字节映射成 ramp 字符 + 三档属性 |

未改动的内核（pxe_default.img）用 `--legacy`：每包都是 `B`，单一绿色，每包一次重绘，会有轻微撕裂。

## 2. 用法

```bash
cd "/c/Users/wu_ha/Documents/JEV 系统/baremetal"
PYTHONUTF8=1 python ascii_cam.py --list                       # 枚举摄像头/麦克风
PYTHONUTF8=1 python ascii_cam.py --once --mirror              # 本地渲一帧看效果（不联网）
PYTHONUTF8=1 python ascii_cam.py                              # QEMU（127.0.0.1:50000）12 fps
PYTHONUTF8=1 python ascii_cam.py 192.168.178.114 --fps 10 --repeat 2 --mirror   # 真机
```

参数：目标 IP（位置参数）、`--port`、`--fps`、`--cols/--rows`（默认 64x48，最多 80x48）、`--cam N`、
`--mirror` 镜像、`--no-track` 关人脸跟踪、`--levels 1|2|3` 亮度档数、`--legacy`、
`--rows-per-packet`（默认 8 → 每包约 650 B，真机安全；QEMU 可 16）、`--repeat N` 冗余、`--gap` 包间隔、
`--subtitle --mic N` 字幕、`--kernel-render` 老 PC 自己转换、`--layout dual` 双头像、`--probe` 测延迟、`--duration`。

双头像 + 对话：`--layout dual` 左边你的 36x36 像、右边 Dario 脸（face_data.inc，每 10 s 用 S 定位写补一遍）；
对话区在左下，agent_chat 用 `CHAT_ROW0=38 CHAT_PANE_H=10` 启动即可写到那里：
```bash
CHAT_ROW0=38 CHAT_PANE_H=10 PYTHONUTF8=1 python agent_chat.py
```

字幕：`--subtitle` 用本机麦克风 → faster-whisper（本地 base 模型，已缓存）→ 老 PC 底行（row 49，col 4-75）。
屏幕字体是 CP437，**显示不了中文**，所以默认 whisper 做 translate 输出英文；`--no-translate` 保留原语言（非 ASCII 字符显示为 ?）。
实测这台 PC 的默认麦克风（Mikrofonarray Intel Smart）录到的全是 0，需要在 Windows 隐私设置/声音设置里确认麦克风，或用 `--mic N` 换设备。

## 3. QEMU 实测（2026-10-21）

- `ascii_cam_qemu_test.py`：私有端口 UDP 50020 / QMP 55620 启 pxe_cam.img，跑 ascii_cam + 截图。
- 12 fps 稳定（设 15 也到 15.1）；每帧 6 包（8 行/包）约 3.9 KB，45 KB/s；渲染 10-22 ms/帧（含 mediapipe）。
- `--probe`（帧内放标记格，用 `Y` 读回帧缓冲像素直到出现）：**发出→上屏中位 6 ms，最大 13 ms**（QEMU）。
  端到端 ≈ 摄像头曝光/采集 ~33-70 ms + 渲染 ~15 ms + 发送 3 ms + 内核重绘 ~6 ms ≈ **0.1 s 级**。
- `--kernel-render`（g 指令，16 行/包 → 3 包/帧）：中位 4 ms。
- 录屏：`promo/ascii_cam_demo.mp4`（qemu-screen-record 技能，QMP stop/screendump/cont）。

## 4. 上真机步骤（吴总操作，脚本不会替换 pxe.img）

老机现在 PXE 拉的是 `pxe.img` = 线虫 v3（41472 B；街机版在 pxe_arcade.img）。要换成带 b/g 指令的聊天脸版：

1. 换镜像（PowerShell，先备份）：
   ```powershell
   cd "C:\Users\wu_ha\Documents\JEV 系统\baremetal"
   Copy-Item pxe.img pxe_before_cam_backup_$(Get-Date -Format yyyyMMdd).img
   Copy-Item pxe_cam.img pxe.img
   ```
   （pxe_cam.img = 当前默认聊天脸内核 + 本次 b/g/属性指令，41 扇区 20992 B；pxe_default.img 是旧版，仍可配 `--legacy` 用。）
2. 确认 pxe_server.py 在跑（它从 baremetal/ 目录发 pxe.img），老机**手动开机**（别重启，开机不可靠），开机即 PXE 不用 F8。
   等开机雨 → Dario 脸动画 → 图形控制台出现 `>` 提示符（约 20 s）。
3. 这台 PC 上：
   ```bash
   cd "/c/Users/wu_ha/Documents/JEV 系统/baremetal"
   PYTHONUTF8=1 python ascii_cam.py 192.168.178.114 --fps 10 --mirror --repeat 2
   ```
   真机带宽：实测通道约 890 包/s、每包 ≤ ~700 B。10 fps × 6 包 × 2 冗余 = 120 包/s，余量很大；
   丢包表现为某一帧某 8 行"停一拍"，下一帧即覆盖。若画面有横条，降 `--fps 8` 或 `--repeat 3`；若流畅可试 `--fps 15 --repeat 1`。
   真机重绘：每帧 present_text 往 UC 显存写 1 MB，12 fps ≈ 12 MB/s，GMA4500 没压力。
4. 双头像 + 聊天：`--layout dual`，另开 `CHAT_ROW0=38 CHAT_PANE_H=10 python agent_chat.py`，老机键盘打字照常。
5. 想让老 PC 自己算字符：加 `--kernel-render --rows-per-packet 8`（每包 644 B）。
6. 换回线虫/街机版：`Copy-Item pxe_before_cam_backup_<日期>.img pxe.img`（或 pxe_worm.img / pxe_arcade.img），再手动开机。

硬约束照旧：不碰 SATA、不碰 agentctl、不覆盖 pxe_worm.img。

## 5. `--layout brain`：你的脸 + 老 PC 自己算的线虫大脑（2026-10-21 加）

右半屏是 C. elegans 302 神经元 LIF 大脑，**每一步都在老 PC 的 CPU 上算**（聊天脸内核内置 brain.asm 的 `n` 指令）。
每帧：摄像头里的动作 → 感觉输入（动得大=头部触觉 ALM/AVM，猛动=尾部 PLM；凑近=ASEL 食物变近，后仰=ASER/AWC）
→ `L` 载入 EXT 向量 → `nS000A` 跑 10 步 → 读回 302 个电位 + 放电位图 → 画成三列组（感觉 2 列 / 中间 3 列 / 运动 3 列）：
`.` `:` 暗绿=静息/上升，`+` `*` `#` 亮绿=接近阈值，`@` 白=本步放电，白 `+`=放电神经元的突触后目标被击中，组间 `-`=信号向右传。
右侧小栏：IN（摄像头触发的刺激）、OUT（前进/后退运动池放电条）、active、lost（丢的 nS 回包）。

```bash
PYTHONUTF8=1 python ascii_cam.py 192.168.178.114 --layout brain --fps 10 --mirror --repeat 2
```
QEMU 实测 12 fps、每帧 6 包 + 1 个 L + 1 个 nS 往返、lost 0。`brain_panel.py` 可单独 import。
