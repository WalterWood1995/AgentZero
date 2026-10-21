# AgentZero 宣传片 · 讲解与介绍 / AgentZero film — narration & descriptions

成片：`promo/agentzero_combo_zh.mp4`（中文字幕）、`promo/agentzero_combo_en.mp4`（英文字幕），1080p30，**1 分 17 秒**；
另有 720p 版 `agentzero_combo_{zh,en}_720p.mp4`。独立字幕 `agentzero_combo_{zh,en}.srt`。一键重剪 `build_combo.sh`。
配乐 `combo_bgm.wav`：`make_disco.py` 程序合成的迷幻迪厅风（126 bpm 四踩底鼓、反拍踩镲、滚动锯齿贝斯+谐振滤波扫频、E 小调失谐锯齿铺底、酸性琶音、侧链抽吸、乒乓延迟；纯 numpy/scipy，无版权）。

**全部画面为吴总手机实拍的真机**（2026-10-21 定版：不用 QEMU 素材，去掉"人脸+线虫脑"段）。

## 结构与素材来源

| 时间 | 段落 | 素材 | 标注 |
|---|---|---|---|
| 0:00–0:05 | 片头字卡 | — | — |
| 0:05–0:07.5 | 第一章字卡「一个真实动物的完整大脑」 | — | — |
| 0:07.5–0:48.7 | 线虫大脑，老机屏幕 | `real_worm_android.mp4`（吴总安卓手机 17:41 拍，41 s） | 真机实拍 · Asus K50IJ (2009) |
| 0:48.7–0:51.2 | 第二章字卡「它用自己的神经网络画出了你的脸」 | — | — |
| 0:51.2–1:11.1 | 老机 NN 生成的脸 + 运算面板 | `real_asciicam_nn_iphone.mov`（吴总 iPhone 21:21 拍，转码 `real_asciicam_nn_1080.mp4`，20 s） | 真机实拍 · Asus K50IJ (2009) |
| 1:11.1–1:17.1 | 片尾字卡：GitHub、数据来源 | — | — |

---

## 一、讲解词（配音用，按时间轴）/ Narration script

| 时间 | 中文 | English |
|---|---|---|
| 0:08 | 这是一台 2009 年的华硕 K50IJ，硬盘控制器坏到任何 Linux 都在开机时卡死。它现在没有操作系统。 | A 2009 Asus K50IJ whose disk controller hangs every Linux at boot. It now has no operating system. |
| 0:13 | 开机从网络拉进一个 41 KB、从零手写的裸机内核，之后拔掉网线，它照样活着。 | At boot it pulls a 41 KB bare-metal kernel, written from scratch, over the network. Then the cable comes out, and it keeps living. |
| 0:18 | 左边是培养皿里的线虫，右边是它的大脑：302 个神经元、10193 个突触，来自公开的 OpenWorm 连接组。 | Left: a worm in a petri dish. Right: its brain — 302 neurons, 10,193 synapses, from the public OpenWorm connectome. |
| 0:23 | 按 H 戳它的头：触觉神经元 ALM/AVM 发放，活动沿连线传到指令神经元，运动区一片洋红——它倒退了。 | Press H to poke its head: touch neurons ALM/AVM fire, activity runs along the wires to the command neurons, the motor area turns magenta — it reverses. |
| 0:29 | 每一条亮起的线都是一个真实突触在这一步被用到。这不是动画，是 CPU 每秒 120 步算出来的状态。 | Every line that lights up is a real synapse used in that step. Not an animation: a state the CPU computes 120 times a second. |
| 0:35 | 身体每一节的弯曲由该体节的背腹肌肉决定；橙色光团是食物，它循着浓度梯度爬过去。 | Each body segment bends by its own dorsal and ventral muscles; the orange glow is food, and it climbs the concentration gradient. |
| 0:40 | 全部计算跑在这颗 2009 年的双核 CPU 上：int16 定点、SSE2 乘加，没有一行操作系统代码。 | All of it runs on this 2009 dual-core CPU: int16 fixed point, SSE2 multiply-add, not one line of OS code. |
| 0:46 | 这是定性的"漫画版"：连接是真实的，神经元动力学是简化的积分发放模型。 | A qualitative cartoon: the wiring is real, the neuron dynamics are a simplified integrate-and-fire model. |
| 0:51 | 第二章。这张脸不是开发机渲染的：摄像头只送来灰度，老机自己的神经网络把每一格算成字符。 | Chapter two. This face is not rendered by the dev PC: the camera only sends grey values, and the old machine's own neural network turns every cell into a character. |
| 0:57 | 一个极小的 MLP：9 个灰度输入、32 个隐藏单元、16 种字形，int16 定点，权重 1.8 KB；每帧 12288 格全在 ring 0 汇编里推理，10 帧每秒。 | A tiny MLP: 9 grey inputs, 32 hidden units, 16 glyphs, int16 fixed point, 1.8 KB of weights; 12,288 cells per frame inferred in ring-0 assembly, 10 frames per second. |
| 1:03 | 右侧面板是模型的运算现场：探针格的输入、隐藏层、输出分数、权重图和乘加过程。 | The right panel is the model at work: the probe cell's input, hidden layer, output scores, weight maps and multiply-adds. |
| 1:08 | 结果与 Python 参考逐格位精确一致。 | Bit-exact against the Python reference, cell for cell. |
| 1:11 | 这一切没有操作系统——没有驱动、没有运行时、没有一行 C——全部是手写的 x86 汇编。 | None of it has an operating system — no drivers, no runtime, not a line of C — all hand-written x86 assembly. |
| 1:14 | 一台报废的笔记本，因此成了一块能看、能想、能被网络直控的裸机算力。 | And so a scrapped laptop became bare-metal compute that can see, can think, and can be driven over the network. |

---

## 二、视频介绍 / Video description

### 中文

**标题**：报废笔记本的两件事：跑一个真实动物的大脑、用自己的神经网络画出你的脸——全部没有操作系统，全部真机实拍

**简介**：
一台 2009 年的华硕 K50IJ，硬盘控制器坏到连 Linux 都装不上。我们不装系统：开机从网络拉进一个 41 KB、从零手写的 x86 裸机内核，之后拔掉网线它照样活着。这条片子是它的两件事，全部由手机对着真机屏幕拍摄：

第一章，一个真实动物的完整大脑。秀丽隐杆线虫的 302 个神经元、10193 个突触（OpenWorm 公开连接组，MIT）作为 int16 定点、SSE2 加速的积分发放网络在它的 CPU 上每秒跑 120 步，驱动培养皿里的虚拟线虫：戳头倒退、戳尾前冲、循着食物梯度爬过去、用咽泵进食。右半屏把 302 个神经元画成网络，谁发放谁的突触就亮。

第二章，它用自己的神经网络画出你的脸。开发机摄像头只送来灰度，老机内核里一个 1.8 KB 权重的极小 MLP 在 ring 0 汇编里逐格推理出每个字符，每帧 12288 格、10 帧每秒，与 Python 参考位精确一致；右侧面板实时展示模型的运算过程。

诚实说明：线虫的动力学是定性的简化模型，连接是真实的。

代码、数据、测试全部开源：github.com/WalterWood1995/AgentZero

**标签**：#裸机 #汇编 #无操作系统 #线虫 #连接组 #OpenWorm #神经网络 #ASCII #老电脑 #AgentZero

### English

**Title**: Two things a scrapped laptop does with no OS: run a real animal's brain, and draw your face with its own neural network — all filmed on the real machine

**Description**:
A 2009 Asus K50IJ whose disk controller is so broken it cannot even boot Linux. We install nothing: at boot it pulls a 41 KB x86 bare-metal kernel, written from scratch, over the network — then the cable comes out and it keeps living. This film is two things it does, all filmed by phone on the real screen:

Chapter one, a real animal's whole brain. The 302 neurons and 10,193 synapses of C. elegans (OpenWorm's public connectome, MIT) run on its CPU as an int16 fixed-point, SSE2-accelerated integrate-and-fire network, 120 steps per second, driving a virtual worm in a petri dish: poke its head and it reverses, poke its tail and it surges, it climbs the food gradient and eats with its pharyngeal pump. The right half of the screen draws the 302 neurons as a network whose synapses flash when a neuron fires.

Chapter two, it draws your face with its own neural network. The dev PC's camera only sends grey values; inside the old kernel a tiny MLP with 1.8 KB of weights infers every character cell in ring-0 assembly — 12,288 cells per frame, 10 frames per second, bit-exact against the Python reference — while the side panel shows the model's computation live.

Honest caveat: the worm's dynamics are a qualitative simplified model; the wiring is real.

Code, data and tests are open source: github.com/WalterWood1995/AgentZero

**Tags**: #baremetal #assembly #noOS #Celegans #connectome #OpenWorm #neuralnetwork #ASCII #retrocomputing #AgentZero

---

## 三、项目介绍 / Project introduction

### 中文

**AgentZero：没有操作系统的笔记本，当作 AI 的裸机身体**

AgentZero 是一个从零手写的 32 位 x86 裸机内核，目标是把一台报废笔记本变成 AI Agent 可以直接驱动的硬件：没有操作系统、没有驱动栈、没有运行时，Agent 通过网络用 ring 0 指令集读写它的 CPU、内存、PCI、端口和帧缓冲。它的起点是一台 2009 年的华硕 K50IJ——SATA 控制器让任何 Linux 都在开机探测存储时卡死——于是干脆绕开存储：PXE 网络启动，内核不碰硬盘，机器反而稳定。

在这个底座上，老机已经做到：网络远程读取真实芯片组；用自己的 CPU 算定点傅里叶级数画出世界地图；裸机聊天终端和网页阅读页；60 fps 的游戏机。这条片子展示的是最近的两步（全部真机实拍）——

**线虫大脑**：C. elegans 的完整连接组（302 神经元、10193 突触，OpenWorm，MIT）压缩成 8 KB 烧进内核，开机展开为 400×304 的 int16 矩阵，每帧用 SSE2 `pmaddwd` 跑两步积分发放。大脑输出直接是动作：A/B 类运动神经元的发放差决定前进倒退，96 块肌肉行的膜电位决定身体每节的弯曲，触觉和化学感觉神经元接收戳击、皿壁、食物浓度，咽部神经元在食物上被驱动。Python 参考实现与内核两条计算路径对账 maxdiff = 0。

**ASCII 实时头像**：开发机摄像头 → 人脸关键点跟踪 → 灰度与对比度处理 → 字符映射 → 每帧约 4 KB 的 UDP 块写；老机内核把文本格按 ROM 字体画进帧缓冲，三档亮度，发出到上屏中位 6 ms，真机 10 fps。

**老机自己的神经网络**：一个极小的 MLP（3×3 邻域 9 输入、32 隐藏、16 字形输出，int16 定点，权重 1.8 KB）在内核里对每帧 12288 个格子逐格推理，生成 ASCII 画面；与 Python 参考逐格位精确一致；屏幕右侧实时展示探针格的输入、隐藏层、输出、权重图和乘加过程。同一块屏幕也能把你的脸和线虫大脑并排：你的动作变成它的感觉输入。

我们坦率地标明每段素材是真机实拍还是 QEMU 演示，并说明线虫动力学是定性的简化模型（三条建模假设见数据说明）。全部代码、数据来源、QEMU 无人测试、对账脚本、拍摄与剪辑脚本开源（MIT）。

### English

**AgentZero: a laptop with no operating system, as a bare-metal body for AI**

AgentZero is a 32-bit x86 bare-metal kernel written from scratch, built to turn a scrapped laptop into hardware an AI agent can drive directly: no operating system, no driver stack, no runtime — the agent reads and writes the CPU, memory, PCI, ports and framebuffer over the network through a ring-0 instruction set. It began with a 2009 Asus K50IJ whose SATA controller hangs every Linux during storage probing, so storage is bypassed altogether: PXE network boot, a kernel that never touches the disk, and the machine is stable.

On that foundation the old machine has already read its real chipset remotely, drawn the world map with a fixed-point Fourier series on its own CPU, run a bare-metal chat terminal and web reader, and a 60 fps game console. This film shows the two most recent steps (all filmed on the real machine) —

**The worm brain**: the complete C. elegans connectome (302 neurons, 10,193 synapses; OpenWorm, MIT) is compacted into 8 KB and baked into the kernel, expanded at boot into a 400×304 int16 matrix, and stepped twice per frame with SSE2 `pmaddwd` integrate-and-fire updates. The brain's output is the action: the A/B motor neuron spike difference sets forward or backward motion, the membrane potentials of 96 muscle rows bend each body segment, touch and chemosensory neurons receive pokes, the dish wall and food concentration, and the pharyngeal neurons are driven on food. The Python reference and both kernel compute paths agree with maxdiff = 0.

**Live ASCII portrait**: dev-PC camera → face landmark tracking → grey/contrast processing → glyph mapping → about 4 KB of UDP block writes per frame; the old kernel paints the text cells from its ROM font into the framebuffer in three brightness levels, send-to-screen median 6 ms, 10 fps on the real machine.

**The old machine's own neural network**: a tiny MLP (9 inputs from a 3×3 neighbourhood, 32 hidden units, 16 glyph outputs, int16 fixed point, 1.8 KB of weights) infers every one of the 12,288 cells per frame inside the kernel, producing the ASCII picture; bit-exact against the Python reference, cell for cell; the side panel shows the probe cell's input, hidden layer, output, weight maps and multiply-adds live. The same screen can also put your face next to the worm brain, with your movements as its sensory input.

Every clip is labelled as real-machine footage or a QEMU demo, and the worm dynamics are stated to be a qualitative simplified model (three modelling assumptions documented with the data). All code, data sources, unattended QEMU tests, bit-exact checks, shooting and editing scripts are open source (MIT).
