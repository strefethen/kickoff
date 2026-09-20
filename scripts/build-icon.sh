#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s SOURCE.png OUTPUT.icns\n' "$0" >&2
    exit 2
fi

task_source="$1"
task_output="$2"
task_output_dir="$(dirname -- "$task_output")"
/bin/mkdir -p "$task_output_dir"
task_work="$(/usr/bin/mktemp -d "$task_output_dir/icon-build.XXXXXX")"
trap '/bin/rm -rf "$task_work"' EXIT
task_iconset="$task_work/AppIcon.iconset"
/bin/mkdir -p "$task_iconset"

for task_points in 16 32 128 256 512; do
    for task_scale in 1 2; do
        task_pixels=$((task_points * task_scale))
        task_suffix=""
        if [ "$task_scale" -eq 2 ]; then task_suffix="@2x"; fi
        /usr/bin/sips -z "$task_pixels" "$task_pixels" "$task_source" \
            --out "$task_iconset/icon_${task_points}x${task_points}${task_suffix}.png" >/dev/null
    done
done

/usr/bin/iconutil --convert icns --output "$task_output" "$task_iconset"
