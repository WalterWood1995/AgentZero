#!/usr/bin/env bash
# build_combo.sh - the AgentZero film, real-machine footage only (no QEMU material):
#   title card -> chapter 1: the worm brain (phone clip real_worm_android.mp4, 41 s)
#   -> chapter 2: the old machine's own neural network draws your face
#      (phone clip real_asciicam_nn_1080.mp4, 20 s) -> end card.           ~77 s
# Outputs agentzero_combo_{zh,en}.mp4 (1080p) + _720p.mp4. Works in an ASCII temp dir.
set -e
BM="$(cd "$(dirname "$0")/.." && pwd)"
P="$BM/promo"
W="${TEMP:-/tmp}/agentzero_combo"
mkdir -p "$W"; cd "$W"; rm -f bgm.wav
cp /c/Windows/Fonts/msyh.ttc ./msyh.ttc 2>/dev/null || true
FONT="fontfile=msyh.ttc"
V="-c:v libx264 -crf 18 -pix_fmt yuv420p -r 30"
SIL="-f lavfi -i anullsrc=r=48000:cl=stereo"
[ -f "$P/real_asciicam_nn_1080.mp4" ] || ffmpeg -v error -y -i "$P/real_asciicam_nn_iphone.mov" -vf "scale=1920:1080,setsar=1,fps=30" -an -c:v libx264 -crf 18 -pix_fmt yuv420p "$P/real_asciicam_nn_1080.mp4"

card() {  # card <name> <textfile> <seconds> <fontsize>
  ffmpeg -v error -y -f lavfi -i color=c=black:s=1920x1080:r=30:d=$3 $SIL \
    -vf "drawtext=$FONT:textfile=$2:fontcolor=white:fontsize=$4:x=(w-text_w)/2:y=(h-text_h)/2:line_spacing=18:alpha='if(lt(t,0.6),t/0.6,if(gt(t,$3-0.6),($3-t)/0.6,1))'" \
    -t $3 $V -c:a aac -shortest $1.mp4
}
tag() {   # tag <in> <out> <label>  - 1080p, corner label, silent
  printf '%s' "$3" > tag.txt
  ffmpeg -v error -y -i "$1" $SIL \
    -vf "scale=-2:1080,pad=1920:1080:(ow-iw)/2:0,setsar=1,fps=30,drawtext=$FONT:textfile=tag.txt:fontcolor=0xC0C0C0:fontsize=26:x=w-text_w-28:y=22:box=1:boxcolor=black@0.5:boxborderw=10" \
    -an $V -c:a aac -shortest "$2"
}

for L in zh en; do
  if [ $L = zh ]; then
    printf '一台 2009 年的报废笔记本 · 没有操作系统 · 从零手写的 x86 汇编\n\n\n它跑着一个真实动物的完整大脑，也用自己的神经网络画出了你的脸' > title.txt
    printf '第一章\n\n一个真实动物的完整大脑' > c1.txt
    printf '第二章\n\n它用自己的神经网络画出了你的脸' > c2.txt
    printf 'AgentZero\ngithub.com/WalterWood1995/AgentZero\n\n线虫连接组：OpenWorm（MIT）\n内核、神经网络、身体模型、可视化：从零手写的 x86 汇编\n\n一台 2009 年的 Asus K50IJ · 没有操作系统 · 全部真机实拍' > end.txt
    REAL="真机实拍 · Asus K50IJ (2009)"
    STYLE="FontName=Microsoft YaHei,FontSize=13,Outline=1.5,Shadow=0.5,MarginV=28,PrimaryColour=&H00FFFFFF"
  else
    printf "A scrapped 2009 laptop - no operating system - x86 assembly written from scratch\n\n\nIt runs a real animal's whole brain, and draws your face with its own neural network" > title.txt
    printf 'Chapter 1\n\nA real animal'"'"'s whole brain' > c1.txt
    printf 'Chapter 2\n\nIt draws your face with its own neural network' > c2.txt
    printf 'AgentZero\ngithub.com/WalterWood1995/AgentZero\n\nWorm connectome: OpenWorm (MIT)\nKernel, neural network, body model, visualisation: x86 assembly from scratch\n\nA 2009 Asus K50IJ - no operating system - all footage is the real machine' > end.txt
    REAL="REAL MACHINE - Asus K50IJ (2009)"
    STYLE="FontName=Arial,FontSize=13,Outline=1.5,Shadow=0.5,MarginV=28,PrimaryColour=&H00FFFFFF"
  fi
  card s0_title_$L title.txt 5 46
  card s1_c1_$L c1.txt 2.5 56
  tag "$P/real_worm_android.mp4" s2_worm_$L.mp4 "$REAL"            # 41.2 s
  card s3_c2_$L c2.txt 2.5 56
  tag "$P/real_asciicam_nn_1080.mp4" s4_nn_$L.mp4 "$REAL"          # 19.9 s
  card s5_end_$L end.txt 6 40
  : > list_$L.txt
  for f in s0_title_$L s1_c1_$L s2_worm_$L s3_c2_$L s4_nn_$L s5_end_$L; do echo "file '$f.mp4'" >> list_$L.txt; done
  ffmpeg -v error -y -f concat -safe 0 -i list_$L.txt -c copy cut_$L.mp4
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 cut_$L.mp4)
  [ -f bgm.wav ] || python "$P/make_bgm.py" bgm.wav $(( ${DUR%.*} + 1 )) --sections "0:cheer" --cheer
  cp "$P/agentzero_combo_$L.srt" $L.srt
  ffmpeg -v error -y -i cut_$L.mp4 -i bgm.wav -map 0:v -map 1:a -vf "subtitles=$L.srt:fontsdir=.:force_style='$STYLE'" \
    -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 -shortest -movflags +faststart "$P/agentzero_combo_$L.mp4"
  ffmpeg -v error -y -i "$P/agentzero_combo_$L.mp4" -vf scale=1280:720 -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart "$P/agentzero_combo_${L}_720p.mp4"
  echo "$L: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$P/agentzero_combo_$L.mp4") s"
done
cp bgm.wav "$P/combo_bgm.wav"
rm -f "$P"/agentzero_combo_*_small.mp4
ls -la "$P"/agentzero_combo_*
