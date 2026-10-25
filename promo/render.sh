#!/bin/zsh
# Renders the Murmur promo in three shapes: square (feed), vertical (Reels/Stories/Shorts), wide (X/LinkedIn/YouTube),
# as a 20 s teaser (murmur-promo-*) and a ~47 s feature tour (murmur-features-*).
# Needs: swiftc, ffmpeg, and a built icon (build/AppIcon.iconset, made by ../build.sh).
# Usage: ./render.sh [teaser|full]   (default: both)
set -euo pipefail
cd "${0:A:h}"
ICON=../build/AppIcon.iconset/icon_512x512@2x.png
BIN=${TMPDIR:-/tmp}/make_promo
swiftc -O make_promo.swift -o $BIN
mkdir -p out
cuts=(${=1:-teaser full})
for cut in $cuts; do
  name=$([[ $cut == full ]] && echo features || echo promo)
  for spec in "square 1080 1080" "vertical 1080 1920" "wide 1920 1080"; do
    set -- ${=spec}
    $BIN $2 $3 $ICON $cut | ffmpeg -y -loglevel error -f rawvideo -pixel_format bgra -video_size ${2}x${3} -framerate 30 -i - \
      -f lavfi -i anullsrc=r=44100:cl=stereo -shortest \
      -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -profile:v high -movflags +faststart -c:a aac -b:a 96k \
      out/murmur-$name-$1.mp4
    echo "done $name $1"
  done
done
