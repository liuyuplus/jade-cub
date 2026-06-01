#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_IMAGE="${ROOT_DIR}/PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
OUTPUT_DIR="${ROOT_DIR}/PingIsland/Assets.xcassets/AppIcon.appiconset"

usage() {
  cat <<'EOF'
Usage: render-app-icons.sh [--source <image-path>] [--output-dir <path>]

Regenerates the macOS AppIcon asset set from a Jade Cub source image.
PNG and SVG inputs are both supported by sips.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      shift
      SOURCE_IMAGE="${1:-}"
      ;;
    --output-dir)
      shift
      OUTPUT_DIR="${1:-}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${SOURCE_IMAGE}" || -z "${OUTPUT_DIR}" ]]; then
  echo "Both source image and output directory are required." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "${SOURCE_IMAGE}" ]]; then
  echo "Source image not found: ${SOURCE_IMAGE}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

render_icon() {
  local size="$1"
  local filename="$2"
  local output_path="${OUTPUT_DIR}/${filename}"
  local input_path="${SOURCE_IMAGE}"
  local temp_source=""

  if [[ "$(cd "$(dirname "$input_path")" && pwd)/$(basename "$input_path")" == "$(cd "$(dirname "$output_path")" && pwd)/$(basename "$output_path")" ]]; then
    temp_source="$(mktemp "${TMPDIR:-/tmp}/jade-cub-icon-source.XXXXXX.png")"
    cp "$input_path" "$temp_source"
    input_path="$temp_source"
  fi

  sips -z "${size}" "${size}" -s format png "${input_path}" --out "${output_path}" >/dev/null

  if [[ -n "$temp_source" ]]; then
    rm -f "$temp_source"
  fi
}

render_icon 16 "icon_16x16.png"
render_icon 32 "icon_32x32 1.png"
render_icon 32 "icon_32x32.png"
render_icon 64 "icon_64x64.png"
render_icon 128 "icon_128x128.png"
render_icon 256 "icon_256x256 1.png"
render_icon 256 "icon_256x256.png"
render_icon 512 "icon_512x512 1.png"
render_icon 512 "icon_512x512.png"
render_icon 1024 "icon_1024x1024.png"

echo "Rendered AppIcon assets from ${SOURCE_IMAGE}"
