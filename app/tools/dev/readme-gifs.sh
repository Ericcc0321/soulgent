#!/bin/bash
# Renders the README's moving pictures off screen from the check binary (build/SoulgentTests, built by test.sh)
# and encodes each: <name>.gif (≤4 MB), .mp4, -contact.png (every third frame), the frames in <name>-frames/, and for the
# sea scenes a -denoise-compare.png (one frame as rendered beside the same frame after the GIF's temporal denoise).
# usage: tools/dev/readme-gifs.sh [--format gif|webp] <out folder> <en|zh-Hans|zh-Hant> <pets folder> [name...]
#   names: desk blaze orca beach queue visit hero office duty (all when none given; webp has no hero, and spotlight
#   is webp only)
#   pets folder: one made by tools/dev/install-demo-pets.sh
#   A scene's old outputs are replaced only once its new frames are all there and every encode has succeeded.
# --format webp: the short pictures instead, one action each, cropped 16:9 to the action, each just restarting at its end:
#   <name>.webp (animated, lossy, quality 80, looping; over 1 MB is reported, over 1.5 MB fails) and <name>.poster.jpg
#   (the frame where the action reads best, at most 150 KB). REVIEW=<folder> also writes <name>-contact.png there
#   (every second frame).
set -euo pipefail
cd "$(dirname "$0")/../.."
FORMAT=gif
if [ "${1:-}" = --format ]; then FORMAT="${2:?format}"; shift 2; fi
case $FORMAT in gif|webp) ;; *) echo "unknown format: $FORMAT" >&2; exit 1;; esac
OUT="${1:?out folder}"; LANG_ID="${2:?language}"; PETS="${3:?pets folder}"; shift 3
BIN=build/SoulgentTests
[ -x "$BIN" ] || { echo "no $BIN (build it with test.sh)" >&2; exit 1; }
[ -d "$PETS" ] || { echo "no pets folder: $PETS (make one with tools/dev/install-demo-pets.sh)" >&2; exit 1; }
for tool in ffmpeg ffprobe; do command -v "$tool" >/dev/null || { echo "no $tool on PATH" >&2; exit 1; }; done
if [ "$FORMAT" = webp ]; then
  for tool in img2webp webpmux; do command -v "$tool" >/dev/null || { echo "no $tool on PATH" >&2; exit 1; }; done
fi
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"; PETS="$(cd "$PETS" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CROP="crop='min(iw,800)':ih:0:0"

# render <dir> <args...>: the frames into $WORK/<dir>. The renderer's own exit status decides; its log is shown filtered,
# and in full when it fails. Then the frames are checked: f000.png up to the count --seconds x --fps gives (rounded half
# away from zero, as the renderer counts), none missing and none more.
render() { local d=$1; shift; echo "== $d $(date +%T)"
  local log="$WORK/$d.log" status=0
  "$BIN" --demo-gif-frames "$WORK/$d" "$@" --lang "$LANG_ID" --pets-dir "$PETS" >"$log" 2>&1 || status=$?
  /usr/bin/grep -a "demo gif" "$log" | /usr/bin/grep -av loops || :
  if [ "$status" -ne 0 ]; then echo "render $d failed (exit $status):" >&2; cat "$log" >&2; exit "$status"; fi
  local fps=15 seconds=6 prev=""
  for a in "$@"; do
    case $prev in --fps) fps=$a;; --seconds) seconds=$a;; esac
    prev=$a
  done
  local want n i
  want=$(awk -v f="$fps" -v s="$seconds" 'BEGIN { printf "%d", f * s + 0.5 }')
  n=$(ls "$WORK/$d" | /usr/bin/grep -a -c '^f[0-9]*\.png$' || :)
  if [ "$n" -ne "$want" ]; then echo "render $d: $n frames, $want expected" >&2; exit 1; fi
  for ((i = 0; i < want; i++)); do
    [ -f "$WORK/$d/$(printf 'f%03d.png' "$i")" ] || { echo "render $d: frame $i missing" >&2; exit 1; }
  done; }

# encode <name> <fps> <sea 0|1>: sea scenes get a temporal denoise and 96 colours from the whole frames (the moving sea
# and orca would take a diff palette's colours from the still pets) to stay under 4 MB.
# The encodes go to $WORK first; the old outputs are replaced only after all three succeeded.
encode() { local src="$WORK/$1" name=$2 fps=$3 sea=$4 pre="$CROP" pal="palettegen=stats_mode=diff" made="$WORK/$1-out"
  if [ "$sea" = 1 ]; then pre="$CROP,hqdn3d=0:0:8:8"; pal="palettegen=max_colors=96:stats_mode=full"; fi
  mkdir -p "$made"
  ffmpeg -v error -y -framerate "$fps" -i "$src/f%03d.png" \
    -vf "$pre,split[a][b];[a]${pal}[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    -loop 0 "$made/$name.gif"
  ffmpeg -v error -y -framerate "$fps" -i "$src/f%03d.png" \
    -vf "$CROP,pad=ceil(iw/2)*2:ceil(ih/2)*2" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "$made/$name.mp4"
  local n rows; n=$(ls "$src" | /usr/bin/grep -a -c '^f[0-9]*\.png$'); rows=$(( (n + 11) / 12 ))
  ffmpeg -v error -y -framerate "$fps" -i "$src/f%03d.png" \
    -vf "$CROP,select='not(mod(n\,3))',scale=400:-1,tile=4x${rows}:padding=4:color=white" -frames:v 1 -update 1 \
    "$made/$name-contact.png"
  mv -f "$made/$name.gif" "$OUT/$name.gif"; mv -f "$made/$name.mp4" "$OUT/$name.mp4"
  mv -f "$made/$name-contact.png" "$OUT/$name-contact.png"
  rm -rf "$OUT/$name-frames"; mv "$src" "$OUT/$name-frames"
  echo "$name: $(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "$OUT/$name.gif")," \
    "$(( $(stat -f %z "$OUT/$name.gif") / 1024 )) KB"; }

# compare <name> <frame n> <w:h:x:y>: that region of frame n, left as rendered, right after hqdn3d=0:0:8:8 run over the
# whole sequence as encode does.
compare() { local src="$OUT/$1-frames" name=$1 n=$2 w h x y; IFS=: read -r w h x y <<< "$3"
  ffmpeg -v error -y -framerate 12 -i "$src/f%03d.png" -filter_complex \
    "[0:v]$CROP,split[r][d];[d]hqdn3d=0:0:8:8[dn];[r][dn]hstack,select='eq(n\,$n)'" -frames:v 1 -update 1 "$WORK/pair.png"
  ffmpeg -v error -y -i "$WORK/pair.png" -filter_complex \
    "[0:v]split[a][b];[a]crop=$w:$h:$x:$y,pad=iw+8:ih:0:0:white[l];[b]crop=$w:$h:$x+800:$y[r];[l][r]hstack" \
    -frames:v 1 -update 1 "$OUT/$name-denoise-compare.png"; }

# webp <name> <out name> <fps> <WxH> <poster frame>: the frames (all exactly WxH) as an animated lossy WebP, each frame
# shown 1000/fps ms rounded, looping; its length checked against the frames'; then the poster from the given frame,
# JPEG at the best quality that keeps it at most 150 KB. The outputs are made in $WORK and moved into place together.
webp() { local src="$WORK/$1" name=$2 fps=$3 size=$4 poster=$5 made="$WORK/$1-out"
  local got; got=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "$src/f000.png")
  [ "$got" = "$size" ] || { echo "$name: frames are $got, $size expected" >&2; exit 1; }
  local n ms frames=() i
  n=$(ls "$src" | /usr/bin/grep -a -c '^f[0-9]*\.png$')
  ms=$(awk -v f="$fps" 'BEGIN { printf "%d", 1000 / f + 0.5 }')
  for ((i = 0; i < n; i++)); do frames+=("$src/$(printf 'f%03d.png' "$i")"); done
  mkdir -p "$made"
  img2webp -loop 0 -lossy -q 80 -m 6 -d "$ms" "${frames[@]}" -o "$made/$name.webp" >/dev/null 2>"$WORK/img2webp.log" \
    || { cat "$WORK/img2webp.log" >&2; echo "$name: img2webp failed" >&2; exit 1; }
  # img2webp merges a frame that does not change into the one before (its duration added), so the check is the length.
  local length; length=$(webpmux -info "$made/$name.webp" | awk '$1 ~ /^[0-9]+:$/ { s += $7 } END { print s + 0 }')
  [ "$length" = "$(( n * ms ))" ] || { echo "$name: the WebP runs ${length} ms, $(( n * ms )) expected ($n frames)" >&2; exit 1; }
  local bytes; bytes=$(stat -f %z "$made/$name.webp")
  [ "$bytes" -le 1572864 ] || { echo "$name: $(( bytes / 1024 )) KB, over 1.5 MB" >&2; exit 1; }
  [ "$bytes" -le 1048576 ] || echo "$name: $(( bytes / 1024 )) KB, over 1 MB" >&2
  [ "$poster" -lt "$n" ] || { echo "$name: no poster frame $poster in $n" >&2; exit 1; }
  local q
  for q in 2 3 4 5 6 7 8 9 10 12 14 16; do
    ffmpeg -v error -y -i "$src/$(printf 'f%03d.png' "$poster")" -q:v "$q" "$made/$name.poster.jpg"
    [ "$(stat -f %z "$made/$name.poster.jpg")" -le 153600 ] && break
  done
  [ "$(stat -f %z "$made/$name.poster.jpg")" -le 153600 ] || { echo "$name: the poster stays over 150 KB" >&2; exit 1; }
  if [ -n "${REVIEW:-}" ]; then
    mkdir -p "$REVIEW"
    ffmpeg -v error -y -framerate "$fps" -i "$src/f%03d.png" \
      -vf "select='not(mod(n\,2))',scale=400:-1,tile=4x$(( (n + 7) / 8 )):padding=4:color=white" -frames:v 1 -update 1 "$REVIEW/$name-contact.png"
  fi
  mv -f "$made/$name.webp" "$OUT/$name.webp"; mv -f "$made/$name.poster.jpg" "$OUT/$name.poster.jpg"
  echo "$name: $size, $(( bytes / 1024 )) KB, $n frames, $(awk -v n="$n" -v ms="$ms" 'BEGIN { printf "%.2f s at %.2f fps", n * ms / 1000, 1000 / ms }')," \
    "poster frame $poster $(( $(stat -f %z "$OUT/$name.poster.jpg") / 1024 )) KB"; }

if [ "$FORMAT" = webp ]; then
  [ $# -eq 0 ] && set -- queue desk blaze orca beach visit office duty spotlight
  for name in "$@"; do
    case $name in
      queue) render queue --only seaview-queue-one --walker ops-k8s --next ai-rag --hold 0.8 --dwell 1.0 --gap 2.4 \
          --fps 15 --seconds 4.9 --width 800; webp queue seaview-queue 15 800x450 18;;
      desk) render desk --only seaview-desk --wide --cut --box 100,268,320,180 --fps 15 --seconds 4 --width 800; webp desk seaview-desk 15 800x450 30;;
      blaze) render blaze --only seaview-blaze --wide --cut --box 430,392,320,180 --switch 2 --hold 5 --fps 15 --seconds 4 --width 800
        webp blaze seaview-blaze 15 800x450 15;;
      orca) render orca --only seaview-orca --wide --cut --start 0.6 --box 758,0,422,237 --fps 12 --seconds 3.6 --width 800; webp orca seaview-orca 12 800x450 30;;
      beach) render beach --only seaview-beach-one --wide --crab 0 --fps 12 --seconds 3.5 --width 640; webp beach seaview-beach 12 640x360 22;;
      visit) render visit --only seaview-visit --wide --cut --box 0,140,444,250 --hold 0.2 --fps 15 --seconds 3.6 --width 800; webp visit seaview-visit 15 800x450 45;;
      office) render office --only office --hold 0.2 --cut --fps 15 --seconds 4.8 --width 800 --box 46,219,696,391.5
        webp office office 15 800x450 36;;
      # The board 940 pt wide (three columns still): its groups from "Done, with news" to the first row of "Seen" fit 16:9.
      # The whole room, 16:9: the Orca light on storefront, then eval-suite, then home-lab (two switches), and again.
      spotlight) render spotlight --only seaview-spotlight --wide --cut --hold 0.4 --fps 12 --seconds 4 --width 960
        webp spotlight seaview-spotlight 12 960x540 20;;
      duty) render duty --only duty-room --fly 0.2 --finish 2.0 --back 600 --fps 15 --seconds 3.4 --width 800 --board 940 \
          --box 6,303,928,522; webp duty duty-room 15 800x450 16;;
      *) echo "unknown: $name" >&2; exit 1;;
    esac
  done
  exit 0
fi

# Simplified Chinese makes the Duty Room shorter: its box stops above the next group's title.
DUTY_BOX=0,300,980,425; [ "$LANG_ID" = zh-Hans ] && DUTY_BOX=0,300,980,416

[ $# -eq 0 ] && set -- desk blaze orca beach queue visit hero office duty
for name in "$@"; do
  case $name in
    desk) render desk --only seaview-desk --fps 15 --seconds 7.48; encode desk seaview-desk 15 0;;
    blaze) render blaze --only seaview-blaze --hold 5 --fps 15 --seconds 8; encode blaze seaview-blaze 15 0;;
    orca) render orca --only seaview-orca --box 680,0,500,345 --fps 12 --seconds 12; encode orca seaview-orca 12 1
      compare seaview-orca 60 400:552:0:0;;
    beach) render beach --only seaview-beach --box 545,0,555,255 --fps 12 --seconds 12; encode beach seaview-beach 12 1
      compare seaview-beach 84 420:368:0:0;;
    queue) render queue --only seaview-queue --walker rag --fps 15 --seconds 7.5 --width 800; encode queue seaview-queue 15 0;;
    visit) render visit --only seaview-visit --fps 15 --seconds 6; encode visit seaview-visit 15 0;;
    hero) render hero --only hero-seaview --fps 12 --seconds 12; encode hero hero-seaview 12 1
      compare hero-seaview 60 400:220:360:20;;
    office) render office --only office --fps 15 --seconds 6 --box 0,200,800,404; encode office office 15 0;;
    duty) render duty --only duty-room --fps 15 --seconds 7.2 --width 800 --box "$DUTY_BOX"; encode duty duty-room 15 0;;
    *) echo "unknown: $name" >&2; exit 1;;
  esac
done
