#!/usr/bin/env bash
# build_combo.sh - the AgentZero combo film: worm brain + ASCII face + face-with-brain + NN face.
# Sources (promo/): real_worm_android.mp4 (phone, real machine), worm_demo.mp4 (QEMU),
# ascii_cam_single_cut.mp4 / ascii_cam_brain_cut.mp4 / ascii_cam_nn_cut.mp4 (QEMU),
# real_asciicam_nn_1080.mp4 (phone, real machine). Outputs agentzero_combo_{zh,en}.mp4 (+720p).
# Works in an ASCII temp dir (QEMU/ffmpeg/libass are unhappy with CJK paths).
set -e
BM="$(cd "$(dirname "$0")/.." && pwd)"
P="$BM/promo"
W="${TEMP:-/tmp}/agentzero_combo"
mkdir -p "$W"; cd "$W"
cp /c/Windows/Fonts/msyh.ttc ./msyh.ttc 2>/dev/null || true
FONT="fontfile=msyh.ttc"
V="-c:v libx264 -crf 18 -pix_fmt yuv420p -r 30"
SIL="-f lavfi -i anullsrc=r=48000:cl=stereo"

card() {  # card <name> <textfile> <seconds> <fontsize>
  ffmpeg -v error -y -f lavfi -i color=c=black:s=1920x1080:r=30:d=$3 $SIL \
    -vf "drawtext=$FONT:textfile=$2:fontcolor=white:fontsize=$4:x=(w-text_w)/2:y=(h-text_h)/2:line_spacing=18:alpha='if(lt(t,0.7),t/0.7,if(gt(t,$3-0.7),($3-t)/0.7,1))'" \
    -t $3 $V -c:a aac -shortest $1.mp4
}
tag() {   # tag <in> <out> <label text> [ss] [t]   - pillarbox/scale to 1080p, corner label, silent
  local ss=""; local tt=""
  [ -n "$4" ] && ss="-ss $4"; [ -n "$5" ] && tt="-t $5"
  printf '%s' "$3" > tag.txt
  ffmpeg -v error -y $ss $tt -i "$1" $SIL \
    -vf "scale=-2:1080,pad=1920:1080:(ow-iw)/2:0,setsar=1,fps=30,drawtext=$FONT:textfile=tag.txt:fontcolor=0xC0C0C0:fontsize=26:x=w-text_w-28:y=22:box=1:boxcolor=black@0.5:boxborderw=10" \
    -an $V -c:a aac -shortest "$2"
}

for L in zh en; do
  if [ $L = zh ]; then
    printf '一台 2009 年的报废笔记本 · 没有操作系统 · 从零手写的 x86 汇编\n\n\n它跑着一个真实动物的完整大脑，也看得见你' > title.txt
    printf '第一章\n\n一个真实动物的完整大脑' > c1.txt
    printf '第二章\n\n它看见了你' > c2.txt
    printf '第三章\n\n你的脸和一个大脑在同一块绿屏' > c3.txt
    printf 'AgentZero\ngithub.com/WalterWood1995/AgentZero\n\n线虫连接组：OpenWorm（MIT）· 人脸关键点：MediaPipe\n内核、神经网络、身体模型、可视化：从零手写的 x86 汇编 + Python 工具链\n\n一台 2009 年的 Asus K50IJ · 没有操作系统' > end.txt
    REAL="真机实拍 · Asus K50IJ (2009)"; QEMU="QEMU 演示 · 同一内核"
    STYLE="FontName=Microsoft YaHei,FontSize=13,Outline=1.5,Shadow=0.5,MarginV=28,PrimaryColour=&H00FFFFFF"
  else
    printf "A scrapped 2009 laptop - no operating system - x86 assembly written from scratch\n\n\nIt runs a real animal's whole brain, and it can see you" > title.txt
    printf 'Chapter 1\n\nA real animal'"'"'s whole brain' > c1.txt
    printf 'Chapter 2\n\nIt sees you' > c2.txt
    printf 'Chapter 3\n\nYour face and a brain on the same green screen' > c3.txt
    printf 'AgentZero\ngithub.com/WalterWood1995/AgentZero\n\nWorm connectome: OpenWorm (MIT) - face landmarks: MediaPipe\nKernel, neural nets, body model, visualisation: x86 assembly from scratch + a Python toolchain\n\nA 2009 Asus K50IJ - no operating system' > end.txt
    REAL="REAL MACHINE - Asus K50IJ (2009)"; QEMU="QEMU DEMO - SAME KERNEL"
    STYLE="FontName=Arial,FontSize=13,Outline=1.5,Shadow=0.5,MarginV=28,PrimaryColour=&H00FFFFFF"
  fi
  card s00_title_$L title.txt 7 48
  card s01_c1_$L c1.txt 3 56
  tag "$P/real_worm_android.mp4" s02_worm_real_$L.mp4 "$REAL"                 # 41.2 s
  tag "$P/worm_demo.mp4" s03_worm_qemu_$L.mp4 "$QEMU" 7 30                    # 30 s
  card s04_c2_$L c2.txt 3 56
  tag "$P/ascii_cam_single_cut.mp4" s05_single_$L.mp4 "$QEMU" 22 16.5         # 16.5 s
  card s06_c3_$L c3.txt 3 56
  tag "$P/ascii_cam_brain_cut.mp4" s07_brain_$L.mp4 "$QEMU"                   # 48 s
  tag "$P/ascii_cam_nn_cut.mp4" s08_nn_$L.mp4 "$QEMU"                         # 48 s
  tag "$P/real_asciicam_nn_1080.mp4" s09_nn_real_$L.mp4 "$REAL"               # 19.9 s
  card s10_end_$L end.txt 8 40
  : > list_$L.txt
  for f in s00_title_$L s01_c1_$L s02_worm_real_$L s03_worm_qemu_$L s04_c2_$L s05_single_$L s06_c3_$L s07_brain_$L s08_nn_$L s09_nn_real_$L s10_end_$L; do
    echo "file '$f.mp4'" >> list_$L.txt
  done
  ffmpeg -v error -y -f concat -safe 0 -i list_$L.txt -c copy cut_$L.mp4
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 cut_$L.mp4)
  # music: one track for both languages, sections follow the chapters
  [ -f bgm.wav ] || python "$P/make_bgm.py" bgm.wav ${DUR%.*} --sections "0:calm,84:bright,103:dense,199:calm"
  cp "$P/agentzero_combo_$L.srt" $L.srt
  ffmpeg -v error -y -i cut_$L.mp4 -i bgm.wav -map 0:v -map 1:a -vf "subtitles=$L.srt:fontsdir=.:force_style='$STYLE'" \
    -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 -shortest -movflags +faststart "$P/agentzero_combo_$L.mp4"
  ffmpeg -v error -y -i "$P/agentzero_combo_$L.mp4" -vf scale=1280:720 -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart "$P/agentzero_combo_${L}_720p.mp4"
  echo "$L: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$P/agentzero_combo_$L.mp4") s"
done
cp bgm.wav "$P/combo_bgm.wav"
ls -la "$P"/agentzero_combo_*
