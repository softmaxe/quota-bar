#!/bin/bash
# Only an explicit documentation allowlist can bypass compilation.
set -euo pipefail

changes="$(mktemp)"
trap 'rm -f "$changes"' EXIT
# Include both paths of renames so moving source into docs still requires a build.
git diff --name-only --no-renames -z "${1:?base revision required}" "${2:?head revision required}" > "$changes"

while IFS= read -r -d '' path; do
    case "$path" in
        README.md|README.zh-CN.md|AGENTS.md|docs/*.md|docs/images/*.png|docs/images/*.jpg|docs/images/*.jpeg|docs/images/*.gif|docs/images/*.webp|docs/images/*.svg)
            ;;
        *)
            echo true
            exit 0
            ;;
    esac
done < "$changes"

echo false
