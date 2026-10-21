# AgentZero 合集片 · 讲解与介绍 / AgentZero combo film — narration & descriptions

成片：`promo/agentzero_combo_zh.mp4`（中文字幕）、`promo/agentzero_combo_en.mp4`（英文字幕），1080p30，约 3 分 47 秒；
另有 720p 版 `agentzero_combo_{zh,en}_720p.mp4`。独立字幕 `agentzero_combo_{zh,en}.srt`。一键重剪 `build_combo.sh`。
配乐 `combo_bgm.wav`：`make_bgm.py` 程序合成（无版权），三段风格随章节变化。

## 结构与素材来源（每段右上角都有标注）

| 时间 | 段落 | 素材 | 标注 |
|---|---|---|---|
| 0:00–0:07 | 片头字卡 | — | — |
| 0:07–0:10 | 第一章字卡「一个真实动物的完整大脑」 | — | — |
| 0:10–0:51 | 线虫大脑，老机屏幕 | `real_worm_android.mp4`（吴总安卓手机 17:41 拍） | **真机实拍 · Asus K50IJ (2009)** |
| 0:51–1:21 | 线虫：戳头/戳尾/进食 | `worm_demo.mp4` 第 7–37 s | QEMU 演示 · 同一内核 |
| 1:21–1:24 | 第二章字卡「它看见了你」 | — | — |
| 1:24–1:40 | 摄像头→ASCII 脸全屏特写 | `ascii_cam_single_cut.mp4` 第 22–38.5 s | QEMU 演示 · 同一内核 |
| 1:40–1:43 | 第三章字卡「你的脸和一个大脑在同一块绿屏」 | — | — |
| 1:43–2:31 | 脸 + 线虫大脑连接组活动 | `ascii_cam_brain_cut.mp4` | QEMU 演示 · 同一内核 |
| 2:31–3:19 | 老机 NN 生成的脸 + 运算面板 | `ascii_cam_nn_cut.mp4` | QEMU 演示 · 同一内核 |
| 3:19–3:39 | 同一布局在真机上 | `real_asciicam_nn_iphone.mov`（吴总 iPhone 21:21 拍，转码为 `real_asciicam_nn_1080.mp4`） | **真机实拍 · Asus K50IJ (2009)** |
| 3:39–3:47 | 片尾字卡：GitHub、数据来源、致谢 | — | — |

诚实说明：QEMU 段与真机跑的是同一个内核镜像；NN 脸在 QEMU（软件模拟）里只有 5 fps，真机原生 10 fps。

---

## 一、讲解词（配音用，按时间轴）/ Narration script

| 时间 | 中文 | English |
|---|---|---|
| 0:10 | 第一章。这是一台 2009 年的华硕 K50IJ，硬盘控制器坏到任何 Linux 都在开机时卡死。它现在没有操作系统。 | Chapter one. A 2009 Asus K50IJ whose disk controller hangs every Linux at boot. It now has no operating system. |
| 0:15 | 开机从网络拉进一个 41 KB、从零手写的裸机内核，之后拔掉网线，它照样活着。 | At boot it pulls a 41 KB bare-metal kernel, written from scratch, over the network. Then the cable comes out, and it keeps living. |
| 0:21 | 左边是培养皿里的线虫，右边是它的大脑：302 个神经元、10193 个突触，来自公开的 OpenWorm 连接组。 | Left: a worm in a petri dish. Right: its brain — 302 neurons, 10,193 synapses, from the public OpenWorm connectome. |
| 0:27 | 按 H 戳它的头：触觉神经元 ALM/AVM 发放，活动沿连线传到指令神经元，运动区一片洋红——它倒退了。 | Press H to poke its head: touch neurons ALM/AVM fire, activity runs along the wires to the command neurons, the motor area turns magenta — it reverses. |
| 0:33 | 每一条亮起的线都是一个真实突触在这一步被用到。这不是动画，是 CPU 每秒 120 步算出来的状态。 | Every line that lights up is a real synapse used in that step. Not an animation: a state the CPU computes 120 times a second. |
| 0:39 | 身体每一节的弯曲由该体节的背腹肌肉决定；橙色光团是食物，它循着浓度梯度爬过去。 | Each body segment bends by its own dorsal and ventral muscles; the orange glow is food, and it climbs the concentration gradient. |
| 0:45 | 全部计算跑在这颗 2009 年的双核 CPU 上：int16 定点、SSE2 乘加，没有一行操作系统代码。 | All of it runs on this 2009 dual-core CPU: int16 fixed point, SSE2 multiply-add, not one line of OS code. |
| 0:51 | 同一个内核在 QEMU 里的无人演示：戳头倒退、戳尾前冲—— | The same kernel in an unattended QEMU run: poke the head, it reverses; poke the tail, it surges — |
| 0:56 | ——放下食物，ASEL/ASER 感知浓度升降，它爬进光团，咽部神经元 NSM/MC 被驱动，慢下来，用咽泵进食。 | — drop food: ASEL/ASER sense the concentration rising and falling, it crawls into the glow, the pharyngeal neurons NSM/MC are driven, it slows down and pumps. |
| 1:03 | 状态行里的 FWD/BWD 是前进、倒退两类运动神经元的实时发放数；每一次反应都来自同一张连接组。 | FWD/BWD in the status line are the live spike counts of the forward and backward motor neurons; every response comes from the same connectome. |
| 1:09 | 这是定性的"漫画版"：连接是真实的，神经元动力学是简化的积分发放模型，三条建模假设都写在数据说明里。 | A qualitative cartoon: the wiring is real, the neuron dynamics are a simplified integrate-and-fire model, with three documented modelling assumptions. |
| 1:24 | 第二章。现在它看见了你：开发机的摄像头拍到人脸，每一帧渲成绿屏 ASCII 数码头像，实时出现在老机屏幕上。 | Chapter two. Now it sees you: the dev PC's camera films a face, every frame becomes a green ASCII portrait, live on the old machine's screen. |
| 1:28 | 摄像头、人脸跟踪和字符映射都在开发机做；一帧只有约 4 KB、6 个 UDP 包，所以能做到实时。 | Camera, face tracking and glyph mapping run on the dev PC; one frame is only about 4 KB, six UDP packets — that is why it is real-time. |
| 1:32 | 老机收到的只是文本格：内核把每个格子按 ROM 字体画进帧缓冲，三档亮度——暗绿、亮绿、白。 | The old machine receives nothing but text cells: the kernel paints each cell from its ROM font into the framebuffer, in three levels — dark green, bright green, white. |
| 1:36 | 从发出到上屏中位 6 毫秒，端到端约 0.1 秒。真机 10 帧每秒；这段是同一内核在 QEMU 里的录屏。 | Send-to-screen median 6 ms, end to end about 0.1 s. 10 fps on the real machine; this clip is the same kernel recorded in QEMU. |
| 1:43 | 第三章。左边是你的脸，右边是线虫的 302 个神经元——两者在同一块绿屏上，大脑的每一步都在老机 CPU 上算。 | Chapter three. Left, your face. Right, the worm's 302 neurons — on the same green screen, every brain step computed on the old CPU. |
| 1:52 | 摄像头里的动作变成感觉输入：动得大是头部触觉，猛动是尾部触觉，凑近是食物变近，后仰是食物远去。 | Camera motion becomes sensory input: a big move is a head touch, a sudden one a tail touch, leaning in is food getting closer, leaning back is food moving away. |
| 2:01 | 每帧内核跑 10 步，读回 302 个膜电位和发放位图：暗绿是静息，亮绿是接近阈值，白色是本步发放。 | Each frame the kernel runs 10 steps and returns 302 membrane potentials and a spike bitmap: dark green resting, bright green near threshold, white firing now. |
| 2:10 | 下方 ACTIVITY 是每步发放数的历史；OUT 是前进与倒退运动池的发放条。 | ACTIVITY below is the history of spikes per step; OUT shows the forward and backward motor pools. |
| 2:19 | 每一次你动，这张连接组就真的被扰动一次——老机算出来的，不是预录的。 | Every time you move, this connectome really is perturbed — computed on the old machine, not pre-recorded. |
| 2:31 | 再看这张脸：它不是开发机渲染的，是老机自己的神经网络一格一格算出来的。 | Now look at the face again: it is not rendered by the dev PC. The old machine's own neural network computes it, cell by cell. |
| 2:40 | 一个极小的 MLP：每格取 3×3 邻域 9 个灰度值，32 个隐藏单元，输出 16 种字形。int16 定点，权重只有 1.8 KB。 | A tiny MLP: 9 grey values from a 3×3 neighbourhood in, 32 hidden units, 16 glyphs out. int16 fixed point; the weights are 1.8 KB. |
| 2:49 | 每帧 12288 个格子，每格一次完整推理，全部在 ring 0 的汇编里跑；结果与 Python 参考逐格位精确一致。 | 12,288 cells per frame, one full inference each, all in ring-0 assembly — bit-exact against the Python reference, cell for cell. |
| 2:58 | 右侧面板是模型的运算现场：探针格的输入、隐藏层、输出分数，W1/W2 权重图，以及逐帧轮播的乘加过程。 | The right panel is the model at work: the probe cell's input, hidden layer and output scores, the W1/W2 weight maps, and the multiply-adds, one per frame. |
| 3:07 | QEMU 里只有 5 帧每秒，真机原生执行 10 帧每秒。这段是 QEMU 录屏——接下来是真机。 | Only 5 fps in QEMU; 10 fps running natively on the real machine. This clip is a QEMU recording — the real machine comes next. |
| 3:19 | 真机实拍：那块 2009 年的屏幕上，左边是它自己的神经网络实时算出的脸，右边是运算面板，10 帧每秒。 | Real machine, filmed by phone: on that 2009 screen, the left is a face its own neural network computes live, the right is the computation panel, 10 fps. |
| 3:26 | 没有操作系统，没有显卡加速，每个字符都是这颗 CPU 逐格推理得到的。 | No operating system, no GPU acceleration — every character is inferred, cell by cell, by this CPU. |
| 3:32 | 从线虫大脑到你的脸，三件事用的是同一套底座：PXE 网络启动、ring 0 指令集、定点整数、SSE2。 | From the worm's brain to your face, the three pieces share one foundation: PXE network boot, a ring-0 instruction set, fixed-point integers, SSE2. |
| 3:39 | 这一切没有操作系统——没有驱动、没有运行时、没有一行 C——全部是手写的 x86 汇编。 | None of it has an operating system — no drivers, no runtime, not a line of C — all hand-written x86 assembly. |
| 3:43 | 一台报废的笔记本，因此成了一块能看、能想、能被网络直控的裸机算力。 | And so a scrapped laptop became bare-metal compute that can see, can think, and can be driven over the network. |

---

## 二、视频介绍 / Video description

### 中文

**标题**：报废笔记本的三件事：跑一个真实动物的大脑、看见你、用自己的神经网络画出你的脸——全部没有操作系统

**简介**：
一台 2009 年的华硕 K50IJ，硬盘控制器坏到连 Linux 都装不上。我们不装系统：开机从网络拉进一个 41 KB、从零手写的 x86 裸机内核，之后拔掉网线它照样活着。这条片子是它的三件事：

第一章，一个真实动物的完整大脑。秀丽隐杆线虫的 302 个神经元、10193 个突触（OpenWorm 公开连接组，MIT）作为 int16 定点、SSE2 加速的积分发放网络在它的 CPU 上每秒跑 120 步，驱动培养皿里的虚拟线虫：戳头倒退、戳尾前冲、循着食物梯度爬过去、用咽泵进食。右半屏把 302 个神经元画成网络，谁发放谁的突触就亮。

第二章，它看见了你。开发机摄像头拍到的脸，每帧渲成绿屏 ASCII 头像，一帧只有约 4 KB，端到端约 0.1 秒，实时出现在老机屏幕上。

第三章，你的脸和一个大脑在同一块绿屏。左边是你，右边是线虫连接组，你的动作变成它的感觉输入；然后这张脸本身也交给老机自己算——一个 1.8 KB 权重的极小 MLP，在 ring 0 汇编里逐格推理出每个字符，与 Python 参考位精确一致，右侧面板实时展示模型的运算过程。

每段都标明了是真机实拍还是 QEMU 演示（同一内核）。诚实说明：线虫的动力学是定性的简化模型，连接是真实的。

代码、数据、测试全部开源：github.com/WalterWood1995/AgentZero

**标签**：#裸机 #汇编 #无操作系统 #线虫 #连接组 #OpenWorm #神经网络 #ASCII #老电脑 #AgentZero

### English

**Title**: Three things a scrapped laptop does with no OS: run a real animal's brain, see you, and draw your face with its own neural network

**Description**:
A 2009 Asus K50IJ whose disk controller is so broken it cannot even boot Linux. We install nothing: at boot it pulls a 41 KB x86 bare-metal kernel, written from scratch, over the network — then the cable comes out and it keeps living. This film is three things it does:

Chapter one, a real animal's whole brain. The 302 neurons and 10,193 synapses of C. elegans (OpenWorm's public connectome, MIT) run on its CPU as an int16 fixed-point, SSE2-accelerated integrate-and-fire network, 120 steps per second, driving a virtual worm in a petri dish: poke its head and it reverses, poke its tail and it surges, it climbs the food gradient and eats with its pharyngeal pump. The right half of the screen draws the 302 neurons as a network whose synapses flash when a neuron fires.

Chapter two, it sees you. A face from the dev PC's camera is rendered into a green ASCII portrait every frame — about 4 KB per frame, roughly 0.1 s end to end — live on the old machine's screen.

Chapter three, your face and a brain on the same green screen. You on the left, the worm's connectome on the right, your movements becoming its sensory input; then the face itself is handed to the old machine — a tiny MLP with 1.8 KB of weights infers every character cell in ring-0 assembly, bit-exact against the Python reference, while the side panel shows the model's computation live.

Every segment is labelled as real-machine footage or a QEMU demo of the same kernel. Honest caveat: the worm's dynamics are a qualitative simplified model; the wiring is real.

Code, data and tests are open source: github.com/WalterWood1995/AgentZero

**Tags**: #baremetal #assembly #noOS #Celegans #connectome #OpenWorm #neuralnetwork #ASCII #retrocomputing #AgentZero

---

## 三、项目介绍 / Project introduction

### 中文

**AgentZero：没有操作系统的笔记本，当作 AI 的裸机身体**

AgentZero 是一个从零手写的 32 位 x86 裸机内核，目标是把一台报废笔记本变成 AI Agent 可以直接驱动的硬件：没有操作系统、没有驱动栈、没有运行时，Agent 通过网络用 ring 0 指令集读写它的 CPU、内存、PCI、端口和帧缓冲。它的起点是一台 2009 年的华硕 K50IJ——SATA 控制器让任何 Linux 都在开机探测存储时卡死——于是干脆绕开存储：PXE 网络启动，内核不碰硬盘，机器反而稳定。

在这个底座上，老机已经做到：网络远程读取真实芯片组；用自己的 CPU 算定点傅里叶级数画出世界地图；裸机聊天终端和网页阅读页；60 fps 的游戏机。这条合集片展示的是最近的三步——

**线虫大脑**：C. elegans 的完整连接组（302 神经元、10193 突触，OpenWorm，MIT）压缩成 8 KB 烧进内核，开机展开为 400×304 的 int16 矩阵，每帧用 SSE2 `pmaddwd` 跑两步积分发放。大脑输出直接是动作：A/B 类运动神经元的发放差决定前进倒退，96 块肌肉行的膜电位决定身体每节的弯曲，触觉和化学感觉神经元接收戳击、皿壁、食物浓度，咽部神经元在食物上被驱动。Python 参考实现与内核两条计算路径对账 maxdiff = 0。

**ASCII 实时头像**：开发机摄像头 → 人脸关键点跟踪 → 灰度与对比度处理 → 字符映射 → 每帧约 4 KB 的 UDP 块写；老机内核把文本格按 ROM 字体画进帧缓冲，三档亮度，发出到上屏中位 6 ms，真机 10 fps。

**老机自己的神经网络**：一个极小的 MLP（3×3 邻域 9 输入、32 隐藏、16 字形输出，int16 定点，权重 1.8 KB）在内核里对每帧 12288 个格子逐格推理，生成 ASCII 画面；与 Python 参考逐格位精确一致；屏幕右侧实时展示探针格的输入、隐藏层、输出、权重图和乘加过程。同一块屏幕也能把你的脸和线虫大脑并排：你的动作变成它的感觉输入。

我们坦率地标明每段素材是真机实拍还是 QEMU 演示，并说明线虫动力学是定性的简化模型（三条建模假设见数据说明）。全部代码、数据来源、QEMU 无人测试、对账脚本、拍摄与剪辑脚本开源（MIT）。

### English

**AgentZero: a laptop with no operating system, as a bare-metal body for AI**

AgentZero is a 32-bit x86 bare-metal kernel written from scratch, built to turn a scrapped laptop into hardware an AI agent can drive directly: no operating system, no driver stack, no runtime — the agent reads and writes the CPU, memory, PCI, ports and framebuffer over the network through a ring-0 instruction set. It began with a 2009 Asus K50IJ whose SATA controller hangs every Linux during storage probing, so storage is bypassed altogether: PXE network boot, a kernel that never touches the disk, and the machine is stable.

On that foundation the old machine has already read its real chipset remotely, drawn the world map with a fixed-point Fourier series on its own CPU, run a bare-metal chat terminal and web reader, and a 60 fps game console. This film shows the three most recent steps —

**The worm brain**: the complete C. elegans connectome (302 neurons, 10,193 synapses; OpenWorm, MIT) is compacted into 8 KB and baked into the kernel, expanded at boot into a 400×304 int16 matrix, and stepped twice per frame with SSE2 `pmaddwd` integrate-and-fire updates. The brain's output is the action: the A/B motor neuron spike difference sets forward or backward motion, the membrane potentials of 96 muscle rows bend each body segment, touch and chemosensory neurons receive pokes, the dish wall and food concentration, and the pharyngeal neurons are driven on food. The Python reference and both kernel compute paths agree with maxdiff = 0.

**Live ASCII portrait**: dev-PC camera → face landmark tracking → grey/contrast processing → glyph mapping → about 4 KB of UDP block writes per frame; the old kernel paints the text cells from its ROM font into the framebuffer in three brightness levels, send-to-screen median 6 ms, 10 fps on the real machine.

**The old machine's own neural network**: a tiny MLP (9 inputs from a 3×3 neighbourhood, 32 hidden units, 16 glyph outputs, int16 fixed point, 1.8 KB of weights) infers every one of the 12,288 cells per frame inside the kernel, producing the ASCII picture; bit-exact against the Python reference, cell for cell; the side panel shows the probe cell's input, hidden layer, output, weight maps and multiply-adds live. The same screen can also put your face next to the worm brain, with your movements as its sensory input.

Every clip is labelled as real-machine footage or a QEMU demo, and the worm dynamics are stated to be a qualitative simplified model (three modelling assumptions documented with the data). All code, data sources, unattended QEMU tests, bit-exact checks, shooting and editing scripts are open source (MIT).
