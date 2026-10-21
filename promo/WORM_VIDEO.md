# 线虫大脑 · 视频讲解与介绍 / C. elegans brain — narration & descriptions

成片：`promo/worm_film_zh.mp4`（中文字幕）、`promo/worm_film_en.mp4`（英文字幕），约 1 分 35 秒，1080p30。
字幕文件：`worm_film_zh.srt` / `worm_film_en.srt`（可直接上传平台做可开关字幕）。
结构：片头字卡 5 s → 手机实拍真机 41 s（保留现场声）→ QEMU 无人演示 43 s（同一内核）→ 片尾 5 s。

---

## 一、讲解词（配音用，按时间轴）/ Narration script

| 时间 | 中文讲解 | English narration |
|---|---|---|
| 0:00 | 一台连 Linux 都装不上的 2009 年笔记本，没有操作系统，用汇编跑着一个真实动物的完整大脑。 | A 2009 laptop that can't even boot Linux. No operating system. A real animal's whole brain, running in assembly. |
| 0:05 | 这是一台 2009 年的华硕 K50IJ。它的硬盘控制器早已让任何 Linux 都在开机时卡死。 | This is a 2009 Asus K50IJ. Its disk controller makes every Linux hang at boot. |
| 0:10 | 现在它没有操作系统：开机从网络拉进一个 41 KB 的裸机内核，之后网线可以拔掉，它照样活着。 | Now it has no OS: it pulls a 41 KB bare-metal kernel over the network at boot; then the cable can be unplugged and it keeps living. |
| 0:15 | 屏幕左边是培养皿里的线虫；右边是它的大脑：302 个神经元、10193 个突触，全部来自公开的 OpenWorm 连接组。 | Left: a worm in a petri dish. Right: its brain — 302 neurons, 10,193 synapses, all from the public OpenWorm connectome. |
| 0:20 | 按下 H 戳它的头：触觉神经元 ALM/AVM 发放，活动沿连线传到指令神经元，运动区一片洋红——它倒退了。 | Press H to poke its head: touch neurons ALM/AVM fire, activity travels along the wires to the command neurons, the motor area turns magenta — it reverses. |
| 0:26 | 每一条亮起的线，都是一个真实的突触在这一步被用到。这不是动画，是 CPU 每秒 120 步算出来的状态。 | Every line that lights up is a real synapse used in that step. Not an animation: a state the CPU computes 120 times a second. |
| 0:31 | 身体每一节的弯曲由对应体节的背腹肌肉激活决定；橙色光团是食物，它闻到梯度就会爬过去。 | Each body segment bends by the activation of its own dorsal and ventral muscles; the orange glow is food, and it crawls up the gradient. |
| 0:37 | 全部计算跑在这颗 2009 年的双核 CPU 上：int16 定点、SSE2 乘加，每帧两步，没有一行操作系统代码。 | All of it runs on this 2009 dual-core CPU: int16 fixed point, SSE2 multiply-add, two brain steps per frame, not one line of OS code. |
| 0:46 | 下面是同一个内核在 QEMU 里的无人演示，画面与真机完全一致。 | What follows is the same kernel in an unattended QEMU run — identical to the real machine. |
| 0:50 | 自由爬行：前进指令神经元 AVB 持续活跃，B 类运动神经元驱动肌肉，身体产生行波。 | Free crawling: the forward command neurons AVB stay active, B-class motor neurons drive the muscles, the body makes a travelling wave. |
| 0:55 | 戳头：ALM/AVM 到 AVD/AVA 的逃逸回路接管，A 类运动神经元发放，线虫倒退、然后转身。 | Poke the head: the ALM/AVM → AVD/AVA escape circuit takes over, A-class motor neurons fire, the worm backs up and turns. |
| 1:00 | 底部状态行的 FWD / BWD 是前进、倒退两类运动神经元的实时发放数。 | FWD / BWD in the status line are the live spike counts of the forward and backward motor neurons. |
| 1:04 | 戳尾：PLM 到 PVC 到 AVB，它向前冲，不会倒退。 | Poke the tail: PLM → PVC → AVB — it surges forward and does not reverse. |
| 1:09 | 放下食物：ASEL / ASER 感知浓度的升降，它循着梯度爬进光团。 | Drop food: ASEL / ASER sense the concentration rising and falling, and it follows the gradient into the glow. |
| 1:14 | 到了食物核心：咽部神经元 NSM / MC 被驱动，它慢下来；头部的蓝点是咽泵在进食，150 次泵动吃完。 | On the food: the pharyngeal neurons NSM / MC are driven, it slows down; the blue dot in the head is the pharynx pumping — 150 pumps and the food is gone. |
| 1:20 | 再戳一次头，它又倒退——每一次反应，都来自同一张连接组。 | Poke the head again and it reverses again — every response comes from the same connectome. |
| 1:25 | 这是定性的"漫画版"：连接是真实的，神经元动力学是简化的积分发放模型。 | This is a qualitative cartoon: the wiring is real, the neuron dynamics are a simplified integrate-and-fire model. |
| 1:30 | AgentZero，开源 MIT。 | AgentZero, open source under MIT. |

---

## 二、视频介绍（平台简介栏用）/ Video description

### 中文

**标题**：报废笔记本里的活线虫：没有操作系统，一个真实动物的完整大脑在 x86 汇编里跑

**简介**：
一台 2009 年的华硕 K50IJ，硬盘控制器坏到连 Linux 都装不上。我们不装系统：开机从网络拉进一个 41 KB、从零手写的裸机内核，拔掉网线它照样活着。内核里跑着秀丽隐杆线虫（C. elegans）的完整连接组——302 个神经元、10193 个突触（OpenWorm 公开数据，MIT 许可）——作为一个 int16 定点、SSE2 加速的积分发放神经网络，每秒 120 步，全部在这颗 2009 年的双核 CPU 上计算。

屏幕左边是培养皿里的虚拟线虫，身体每一节的弯曲由对应体节的背腹肌肉激活决定；右边是它的大脑：神经元按感觉→中间→运动分层，突触画成连线，谁发放谁的出边就亮。戳它的头，它倒退；戳尾巴，它前冲；放下食物，它循着浓度梯度爬过去，到了核心慢下来、用咽泵进食。每一次反应都来自同一张连接组，不是脚本动画。

诚实说明：这是"漫画版"仿真——连接是真的，神经元动力学是简化模型，并加了三条有文献依据的建模假设（触觉逃逸回路、前进/倒退指令互抑、失去气味的掉头回路）。后半段是同一内核在 QEMU 里的无人演示录屏。

代码、数据、测试、拍摄脚本全部开源：github.com/WalterWood1995/AgentZero

**标签**：#裸机 #汇编 #线虫 #连接组 #OpenWorm #神经网络 #老电脑 #无操作系统 #AgentZero

### English

**Title**: A living worm inside a dead laptop: no OS, a real animal's whole brain running in x86 assembly

**Description**:
A 2009 Asus K50IJ whose disk controller is so broken it can't even boot Linux. We don't install anything: at boot it pulls a 41 KB bare-metal kernel, written from scratch, over the network — then the cable can be unplugged and it keeps living. Inside runs the complete connectome of the nematode C. elegans — 302 neurons, 10,193 synapses (OpenWorm public data, MIT) — as an int16 fixed-point, SSE2-accelerated integrate-and-fire network, 120 steps per second, all computed on that 2009 dual-core CPU.

Left: a virtual worm in a petri dish, each body segment bent by the activation of its own dorsal and ventral muscles. Right: its brain, neurons layered sensory → interneurons → motor, synapses drawn as wires, a neuron's wires flashing when it fires. Poke its head and it reverses; poke the tail and it surges forward; drop food and it follows the concentration gradient, slows down on the core and eats with its pharyngeal pump. Every response comes from the same connectome — nothing is scripted.

Honest caveat: this is a cartoon simulation — the wiring is real, the neuron dynamics are a simplified model plus three documented, literature-based assumptions (the touch escape circuit, forward/backward command mutual inhibition, the lost-the-scent pirouette circuit). The second half is the same kernel recorded in an unattended QEMU run.

Code, data, tests and shooting script are open source: github.com/WalterWood1995/AgentZero

**Tags**: #baremetal #assembly #Celegans #connectome #OpenWorm #neuralnetwork #retrocomputing #noOS #AgentZero

---

## 三、项目介绍 / Project introduction

### 中文

**AgentZero · 线虫大脑**

AgentZero 是一个给 AI Agent 造的裸机内核：没有操作系统，一块从零手写的 32 位 x86 内核直接驱动一台报废笔记本的硬件，Agent 通过网络用 ring-0 指令集操作它。它的来历是一台 2009 年的华硕 K50IJ——SATA 控制器让任何 Linux 都在开机探测存储时卡死，于是我们干脆绕开存储：PXE 网络启动，内核不碰硬盘，机器反而稳了。此前它已经做到：网络远程读取真实芯片组、在自己的 CPU 上用定点傅里叶级数画出世界地图、裸机聊天终端、浏览器阅读页、60 fps 的游戏机。

"线虫大脑"是这条路线的下一步：把"游戏"换成**可以在老机器本机跑的真实动物神经网络**。我们选了秀丽隐杆线虫 C. elegans——唯一连接组完整公开的动物：302 个神经元、约一万个突触（OpenWorm，MIT 许可，底层是 White 1986 / Varshney 2011）。上位机把连接组整理成 8 KB 的压缩稀疏表烧进内核；开机时内核把它展开成 400×304 的 int16 稠密矩阵，每帧用 SSE2 `pmaddwd` 做两步积分发放更新——突触求和、泄漏、阈值、不应期、适应、全局抑制——全部在老机的 CPU 上。Python 里有一份逐位一致的参考实现，内核的两条计算路径（SSE2 稠密、标量稀疏）与它对账 maxdiff = 0。

大脑的输出直接变成动作："模型输出即动作"。B 类与 A 类运动神经元的发放差决定前进或倒退；96 块体壁肌肉行的膜电位决定身体每一节怎么弯；触觉神经元 ALM/AVM/PLM 接收戳击和皿壁，化学感觉神经元 ASEL/ASER/AWC 接收食物浓度的升降，咽部神经元 NSM/MC 在食物上被驱动——于是它会倒退、前冲、趋食、减速、进食。屏幕右半把 302 个神经元画成分层网络，突触是连线，发放时出边亮起，让人直接看到活动在连接组里传播。

我们坦率地说这是"定性漫画版"：连接是真实的，动力学是简化的 LIF；原始权重直接用会要么全哑要么雪崩，必须加行归一、发放适应、全局抑制三项稳态机制，再加三条有文献依据的假设（Chalfie 1985 触觉逃逸回路、前进/倒退指令互抑、Gray 2005 失去气味掉头回路），都写在数据说明里。随机觅食只是统计意义上的趋近。

全部代码、数据来源、QEMU 无人测试、对账脚本、拍摄脚本开源（MIT）。下一步候选：果蝇幼虫脑（约 3000 神经元、55 万突触）。

### English

**AgentZero · the C. elegans brain**

AgentZero is a bare-metal kernel built for AI agents: no operating system, a 32-bit x86 kernel written from scratch drives the hardware of a scrapped laptop directly, and an agent operates it over the network through a ring-0 instruction set. It started with a 2009 Asus K50IJ whose SATA controller hangs every Linux during storage probing at boot — so we bypass storage entirely: PXE network boot, a kernel that never touches the disk, and the machine is stable. It had already read its real chipset remotely, drawn the world map with a fixed-point Fourier series on its own CPU, run a bare-metal chat terminal, a web reader and a 60 fps game console.

The worm brain is the next step on that road: replace the "game" with a **real animal's nervous system that runs on the old machine itself**. We chose C. elegans, the only animal with a complete public connectome: 302 neurons, about ten thousand synapses (OpenWorm, MIT licence; underlying data White 1986 / Varshney 2011). A host script compacts the connectome into an 8 KB sparse table baked into the kernel; at boot the kernel expands it into a 400×304 int16 dense matrix and runs two integrate-and-fire steps per frame with SSE2 `pmaddwd` — synaptic sum, leak, threshold, refractory reset, adaptation, global inhibition — entirely on the old CPU. A bit-exact Python reference exists, and both kernel paths (SSE2 dense and scalar sparse) match it with maxdiff = 0.

The brain's output is the action: the difference between B-class and A-class motor neuron spikes sets forward or backward motion; the membrane potentials of the 96 body-wall muscle rows set how every segment bends; the touch neurons ALM/AVM/PLM receive pokes and the dish wall, the chemosensory neurons ASEL/ASER/AWC receive rising and falling food concentration, the pharyngeal neurons NSM/MC are driven on food — so the worm reverses, surges, follows the gradient, slows down and eats. The right half of the screen draws the 302 neurons as a layered network with synapses as wires that flash when the neuron fires, so you watch activity propagate through the connectome.

We say plainly that this is a qualitative cartoon: the wiring is real, the dynamics are simplified LIF. The raw weights alone either stay silent or avalanche, so three homeostatic mechanisms (row normalisation, spike-frequency adaptation, global inhibition) and three literature-based assumptions (the Chalfie 1985 touch escape circuit, forward/backward command mutual inhibition, the Gray 2005 lost-the-scent pirouette circuit) were added and documented. Random foraging is only statistically biased toward food.

All code, data sources, unattended QEMU tests, bit-exact checks and the shooting script are open source (MIT). Next candidate: the Drosophila larva brain (~3,000 neurons, ~550,000 synapses).
