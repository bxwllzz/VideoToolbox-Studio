#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "用法：$0 <IPA 路径> <UITests Runner ZIP 路径> <结果目录>" >&2
  exit 2
fi

readonly ipa_path="$1"
readonly test_suite_path="$2"
readonly result_directory="$3"
readonly api_root="https://api-cloud.browserstack.com/app-automate/xcuitest/v2"
readonly devices_url="https://api-cloud.browserstack.com/app-automate/devices.json"

if [[ ! -f "${ipa_path}" ]]; then
  echo "错误：未找到 IPA：${ipa_path}" >&2
  exit 1
fi

if [[ ! -f "${test_suite_path}" ]]; then
  echo "错误：未找到 XCUITest 测试包：${test_suite_path}" >&2
  exit 1
fi

if [[ -z "${BROWSERSTACK_USERNAME:-}" || -z "${BROWSERSTACK_ACCESS_KEY:-}" ]]; then
  echo "错误：缺少 BROWSERSTACK_USERNAME 或 BROWSERSTACK_ACCESS_KEY。" >&2
  exit 1
fi

mkdir -p "${result_directory}/logs"

readonly auth="${BROWSERSTACK_USERNAME}:${BROWSERSTACK_ACCESS_KEY}"
readonly short_sha="${GITHUB_SHA:-local}"
readonly custom_suffix="${short_sha:0:12}-${GITHUB_RUN_ID:-local}"

echo "正在读取 BrowserStack 可用真机列表。"
curl \
  --silent \
  --show-error \
  --fail-with-body \
  --user "${auth}" \
  "${devices_url}" \
  > "${result_directory}/devices.json"

selected_device="$(
  jq -r '
    [
      .[]
      | select(.os == "ios")
      | select(.real_mobile == true)
      | select(.device | startswith("iPhone"))
      | select(
          try ((.os_version | tostring | split(".")[0] | tonumber) >= 26)
          catch false
        )
    ]
    | sort_by([
        (.os_version | tostring | split(".") | map(tonumber)),
        (if (.device | contains("Pro")) then 1 else 0 end),
        .device
      ])
    | last
    | if . == null then "" else "\(.device)-\(.os_version)" end
  ' "${result_directory}/devices.json"
)"
readonly selected_device

if [[ -z "${selected_device}" ]]; then
  echo "错误：BrowserStack 账号当前没有可用的 iOS 26 或更高版本 iPhone。" >&2
  exit 1
fi

jq -n \
  --arg selected_device "${selected_device}" \
  '{selected_device: $selected_device}' \
  > "${result_directory}/selected-device.json"
echo "已选择真机：${selected_device}"

echo "正在上传未签名 IPA；BrowserStack 将在执行前自动重签。"
curl \
  --silent \
  --show-error \
  --fail-with-body \
  --user "${auth}" \
  --request POST \
  "${api_root}/app" \
  --form "file=@${ipa_path}" \
  --form "custom_id=VideoToolboxStudio-${custom_suffix}" \
  > "${result_directory}/app-upload.json"

readonly app_url="$(jq -r '.app_url // empty' "${result_directory}/app-upload.json")"
if [[ "${app_url}" != bs://* ]]; then
  echo "错误：BrowserStack 未返回有效 app_url。" >&2
  exit 1
fi

echo "正在上传 XCUITest Runner。"
curl \
  --silent \
  --show-error \
  --fail-with-body \
  --user "${auth}" \
  --request POST \
  "${api_root}/test-suite" \
  --form "file=@${test_suite_path}" \
  --form "custom_id=VideoToolboxStudioCloudTests-${custom_suffix}" \
  > "${result_directory}/test-suite-upload.json"

readonly test_suite_url="$(jq -r '.test_suite_url // empty' "${result_directory}/test-suite-upload.json")"
if [[ "${test_suite_url}" != bs://* ]]; then
  echo "错误：BrowserStack 未返回有效 test_suite_url。" >&2
  exit 1
fi

jq -n \
  --arg app "${app_url}" \
  --arg test_suite "${test_suite_url}" \
  --arg device "${selected_device}" \
  --arg build_tag "GitHub_${GITHUB_RUN_NUMBER:-local}" \
  '{
    app: $app,
    testSuite: $test_suite,
    devices: [$device],
    project: "VideoToolboxStudio",
    buildTag: $build_tag,
    resignApp: true,
    deviceLogs: true,
    debugscreenshots: true,
    video: true,
    idleTimeout: 180
  }' \
  > "${result_directory}/build-request.json"

echo "正在启动 BrowserStack XCUITest。"
curl \
  --silent \
  --show-error \
  --fail-with-body \
  --user "${auth}" \
  --request POST \
  "${api_root}/build" \
  --header "Content-Type: application/json" \
  --data "@${result_directory}/build-request.json" \
  > "${result_directory}/build-start.json"

readonly build_id="$(jq -r '.build_id // empty' "${result_directory}/build-start.json")"
if [[ -z "${build_id}" ]]; then
  echo "错误：BrowserStack 未返回 build_id。" >&2
  exit 1
fi

echo "BrowserStack 构建编号：${build_id}"
build_status=""
for attempt in $(seq 1 60); do
  curl \
    --silent \
    --show-error \
    --fail-with-body \
    --user "${auth}" \
    "${api_root}/builds/${build_id}" \
    > "${result_directory}/build-current.json"

  build_status="$(jq -r '.status // empty' "${result_directory}/build-current.json")"
  echo "第 ${attempt} 次查询：${build_status:-未知}"

  case "${build_status}" in
    passed | failed | error | timedout)
      break
      ;;
  esac

  sleep 20
done

cp "${result_directory}/build-current.json" "${result_directory}/build-final.json"

while IFS= read -r session_id; do
  [[ -n "${session_id}" ]] || continue
  session_path="${result_directory}/session-${session_id}.json"

  curl \
    --silent \
    --show-error \
    --fail-with-body \
    --user "${auth}" \
    "${api_root}/builds/${build_id}/sessions/${session_id}" \
    > "${session_path}"

  log_index=0
  while IFS= read -r log_url; do
    [[ -n "${log_url}" ]] || continue
    log_index=$((log_index + 1))
    curl \
      --silent \
      --show-error \
      --fail-with-body \
      --user "${auth}" \
      "${log_url}" \
      > "${result_directory}/logs/session-${session_id}-${log_index}.log"
  done < <(
    jq -r '
      ..
      | objects
      | .instrumentation_log?
      // .instrumentationlogs?
      // empty
    ' "${session_path}" | sort -u
  )
done < <(
  jq -r '.devices[]?.sessions[]?.id // empty' "${result_directory}/build-final.json"
)

report_token="$(
  grep -h -o 'VT_CLOUD_REPORT_BASE64=[A-Za-z0-9+/=]*' \
    "${result_directory}"/logs/*.log 2>/dev/null \
    | tail -n 1 \
    | cut -d= -f2- \
    || true
)"
readonly report_token

if [[ -n "${report_token}" ]]; then
  printf '%s' "${report_token}" \
    | openssl base64 -d -A \
    > "${result_directory}/capability-summary.json"
fi

if [[ "${build_status}" != "passed" ]]; then
  echo "错误：BrowserStack 真机测试状态为 ${build_status:-未知}。" >&2
  exit 1
fi

if [[ ! -s "${result_directory}/capability-summary.json" ]]; then
  echo "错误：测试虽然通过，但未从日志回收到能力摘要。" >&2
  exit 1
fi

echo "BrowserStack 真机测试与报告回收全部通过。"
