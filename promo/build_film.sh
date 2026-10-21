#!/usr/bin/env bash
# build_film.sh - cut the phone video (real machine) + the QEMU recording into one film,
# then burn Chinese / English subtitles. Run from the scratchpad film dir (ASCII path).
set -e
F="$(cd "$(dirname "$0")" && pwd)"
BM="/c/Users/wu_ha/Documents/JEV 系统/baremetal"
cp "$BM/promo/worm_demo.mp4" "$F/qemu.mp4"
cp "$BM/promo/worm_film_zh.srt" "$F/zh.srt"
cp "$BM/promo/worm_film_en.srt" "$F/en.srt"
cd "$F"
FONT="fontfile=msyh.ttc"
# ---- language-specific title / end cards ----
printf '一台连 Linux 都装不上的 2009 年笔记本\n没有操作系统，用汇编跑着一个真实动物的完整大脑\n\n\nC. elegans · 302 神经元 · 10193 突触 · 裸机 x86' > title_zh.txt
printf "A 2009 laptop that can't even boot Linux.\nNo operating system. A real animal's whole brain, in assembly.\n\n\nC. elegans - 302 neurons - 10,193 synapses - bare-metal x86" > title_en.txt
printf 'AgentZero\ngithub.com/WalterWood1995/AgentZero\n\n线虫连接组：OpenWorm（MIT）\n内核、身体模型、可视化：从零手写的 x86 汇编' > end_zh.txt
printf 'AgentZero\ngithub.com/WalterWood1995/AgentZero\n\nWorm connectome: OpenWorm (MIT)\nKernel, body model, visualisation: x86 assembly written from scratch' > end_en.txt
for L in zh en; do
  # segment 1: title card 5 s (silent)
  ffmpeg -v error -y -f lavfi -i color=c=black:s=1920x1080:r=30:d=5 -f lavfi -i anullsrc=r=48000:cl=stereo \
    -vf "drawtext=$FONT:textfile=title_$L.txt:fontcolor=white:fontsize=52:x=(w-text_w)/2:y=(h-text_h)/2:line_spacing=18:alpha='if(lt(t,0.8),t/0.8,if(gt(t,4.2),(5-t)/0.8,1))'" \
    -t 5 -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -shortest seg1_$L.mp4
  # segment 2: phone video (real machine), keep its sound
  ffmpeg -v error -y -i ../phone/phone.mp4 -vf "scale=1920:1080,setsar=1,fps=30" -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -ar 48000 -ac 2 seg2.mp4
  # segment 3: QEMU recording, pillarboxed, silent
  ffmpeg -v error -y -i qemu.mp4 -f lavfi -i anullsrc=r=48000:cl=stereo \
    -vf "scale=-2:1080,pad=1920:1080:(ow-iw)/2:0,setsar=1,fps=30" -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -shortest seg3.mp4
  # segment 4: end card 5 s
  ffmpeg -v error -y -f lavfi -i color=c=black:s=1920x1080:r=30:d=5 -f lavfi -i anullsrc=r=48000:cl=stereo \
    -vf "drawtext=$FONT:textfile=end_$L.txt:fontcolor=white:fontsize=48:x=(w-text_w)/2:y=(h-text_h)/2:line_spacing=18:alpha='if(lt(t,0.8),t/0.8,1)'" \
    -t 5 -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -shortest seg4_$L.mp4
  printf "file 'seg1_%s.mp4'\nfile 'seg2.mp4'\nfile 'seg3.mp4'\nfile 'seg4_%s.mp4'\n" $L $L > list_$L.txt
  ffmpeg -v error -y -f concat -safe 0 -i list_$L.txt -c copy cut_$L.mp4
  # burn subtitles
  if [ $L = zh ]; then STYLE="FontName=Microsoft YaHei,FontSize=20,Outline=2,Shadow=1,MarginV=36,PrimaryColour=&H00FFFFFF"; else STYLE="FontName=Arial,FontSize=20,Outline=2,Shadow=1,MarginV=36,PrimaryColour=&H00FFFFFF"; fi
  ffmpeg -v error -y -i cut_$L.mp4 -vf "subtitles=$L.srt:fontsdir=.:force_style='$STYLE'" -c:v libx264 -crf 19 -pix_fmt yuv420p -c:a copy film_$L.mp4
  cp film_$L.mp4 "$BM/promo/worm_film_$L.mp4"
  ffprobe -v error -show_entries format=duration -of csv=p=0 film_$L.mp4
done
ls -la "$BM/promo/worm_film_"*
