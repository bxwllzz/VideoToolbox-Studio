#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "用法：$0 <输出 JSON 路径>" >&2
  exit 2
fi

readonly output_path="$1"
readonly commit_sha="${BUILD_COMMIT_SHA:-${GITHUB_SHA:-local}}"
readonly build_timestamp="${BUILD_TIMESTAMP:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"
readonly run_id="${BUILD_RUN_ID:-${GITHUB_RUN_ID:-local}}"
readonly run_number="${BUILD_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
readonly xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
readonly sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
readonly image_os="${ImageOS:-unknown}"
readonly image_version="${ImageVersion:-unknown}"
readonly repository="${GITHUB_REPOSITORY:-local}"

if [[ -n "${APP_INFO_PLIST:-}" ]]; then
  if [[ ! -f "${APP_INFO_PLIST}" ]]; then
    echo "错误：未找到 App Info.plist：${APP_INFO_PLIST}" >&2
    exit 1
  fi
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_INFO_PLIST}")"
else
  app_version="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
fi

if [[ -z "${app_version}" ]]; then
  echo "错误：无法确定 App 版本" >&2
  exit 1
fi
readonly app_version

mkdir -p "$(dirname "${output_path}")"

jq -n \
  --arg schema_version "1.0" \
  --arg app_name "VideoToolbox Studio" \
  --arg app_version "${app_version}" \
  --arg build_number "${run_number}" \
  --arg bundle_id "io.github.bxwllzz.VideoToolboxStudio" \
  --arg commit_sha "${commit_sha}" \
  --arg built_at "${build_timestamp}" \
  --arg build_run_id "${run_id}" \
  --arg repository "${repository}" \
  --arg runner_os "${image_os}" \
  --arg runner_image "${image_version}" \
  --arg xcode "${xcode_version}" \
  --arg iphoneos_sdk "${sdk_version}" \
  '{
    schema_version: $schema_version,
    app_name: $app_name,
    app_version: $app_version,
    build_number: $build_number,
    bundle_id: $bundle_id,
    commit_sha: $commit_sha,
    built_at: $built_at,
    build_run_id: $build_run_id,
    repository: $repository,
    toolchain: {
      runner_os: $runner_os,
      runner_image: $runner_image,
      xcode: $xcode,
      iphoneos_sdk: $iphoneos_sdk
    }
  }' > "${output_path}"
