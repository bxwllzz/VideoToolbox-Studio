#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "用法：$0 <IPA 路径> <XCUITest Runner ZIP 路径> <结果目录>" >&2
  exit 2
fi

readonly ipa_path="$1"
readonly test_package_path="$2"
readonly result_directory="$3"
readonly aws_region="${AWS_REGION:-us-west-2}"
readonly project_arn="${AWS_DEVICE_FARM_PROJECT_ARN:-}"
readonly minimum_ios_major="${AWS_DEVICE_FARM_MIN_IOS_MAJOR:-26}"

if [[ ! -f "${ipa_path}" ]]; then
  echo "错误：未找到 IPA：${ipa_path}" >&2
  exit 1
fi

if [[ ! -f "${test_package_path}" ]]; then
  echo "错误：未找到 XCUITest 测试包：${test_package_path}" >&2
  exit 1
fi

if [[ -z "${project_arn}" ]]; then
  echo "错误：缺少 AWS_DEVICE_FARM_PROJECT_ARN。" >&2
  exit 1
fi

for command_name in aws curl jq openssl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "错误：运行环境缺少 ${command_name}。" >&2
    exit 1
  fi
done

mkdir -p \
  "${result_directory}/artifacts/files" \
  "${result_directory}/artifacts/logs" \
  "${result_directory}/artifacts/screenshots" \
  "${result_directory}/metadata"

create_and_process_upload() {
  local source_path="$1"
  local upload_type="$2"
  local result_prefix="$3"
  local upload_name
  local upload_url
  local upload_arn
  local upload_status=""
  local raw_metadata

  raw_metadata="$(mktemp)"

  upload_name="$(basename "${source_path}")"
  aws devicefarm create-upload \
    --project-arn "${project_arn}" \
    --name "${upload_name}" \
    --type "${upload_type}" \
    --content-type "application/octet-stream" \
    --region "${aws_region}" \
    > "${raw_metadata}"

  upload_url="$(
    jq -r '.upload.url // empty' "${raw_metadata}"
  )"
  upload_arn="$(
    jq -r '.upload.arn // empty' "${raw_metadata}"
  )"
  jq '(.upload |= del(.url))' \
    "${raw_metadata}" \
    > "${result_directory}/metadata/${result_prefix}-upload-created.json"

  if [[ -z "${upload_url}" || -z "${upload_arn}" ]]; then
    echo "错误：Device Farm 没有返回 ${upload_type} 的上传地址或 ARN。" >&2
    return 1
  fi

  curl \
    --silent \
    --show-error \
    --fail-with-body \
    --request PUT \
    --header "Content-Type: application/octet-stream" \
    --upload-file "${source_path}" \
    --output /dev/null \
    "${upload_url}"

  for attempt in $(seq 1 120); do
    aws devicefarm get-upload \
      --arn "${upload_arn}" \
      --region "${aws_region}" \
      > "${raw_metadata}"

    jq '(.upload |= del(.url))' \
      "${raw_metadata}" \
      > "${result_directory}/metadata/${result_prefix}-upload-current.json"

    upload_status="$(
      jq -r '.upload.status // empty' \
        "${result_directory}/metadata/${result_prefix}-upload-current.json"
    )"
    echo "${upload_type} 第 ${attempt} 次处理状态：${upload_status:-未知}" >&2

    case "${upload_status}" in
      SUCCEEDED)
        break
        ;;
      FAILED)
        jq -r '.upload.message // "Device Farm 未提供失败说明。"' \
          "${result_directory}/metadata/${result_prefix}-upload-current.json" >&2
        return 1
        ;;
    esac

    sleep 10
  done

  cp \
    "${result_directory}/metadata/${result_prefix}-upload-current.json" \
    "${result_directory}/metadata/${result_prefix}-upload-final.json"

  if [[ "${upload_status}" != "SUCCEEDED" ]]; then
    echo "错误：${upload_type} 在等待窗口内未处理完成。" >&2
    return 1
  fi

  rm -f "${raw_metadata}"
  printf '%s' "${upload_arn}"
}

echo "正在上传并处理未签名测试版 IPA。"
app_upload_arn="$(
  create_and_process_upload \
    "${ipa_path}" \
    "IOS_APP" \
    "app"
)"
readonly app_upload_arn

echo "正在上传并处理 XCUITest Runner。"
test_upload_arn="$(
  create_and_process_upload \
    "${test_package_path}" \
    "XCTEST_UI_TEST_PACKAGE" \
    "test"
)"
readonly test_upload_arn

echo "正在读取 Device Farm 公共 iPhone 清单。"
aws devicefarm list-devices \
  --region "${aws_region}" \
  > "${result_directory}/metadata/devices.json"

selected_device="$(
  jq \
    --argjson minimum_major "${minimum_ios_major}" \
    '
      [
        .devices[]
        | select(.platform == "IOS")
        | select(.formFactor == "PHONE")
        | . + {
            parsed_os: (
              (.os | tostring | split(".") | map(tonumber? // 0))
              + [0, 0, 0]
            )[0:3],
            major: (
              try (.os | tostring | split(".")[0] | tonumber)
              catch 0
            ),
            model_priority: (
              if .model == "iPhone 17 Pro" then 4
              elif .model == "iPhone 17 Pro Max" then 3
              elif (.model | contains("Pro")) then 2
              elif (.model | startswith("iPhone 17")) then 1
              else 0
              end
            ),
            availability_priority: (
              if .availability == "HIGHLY_AVAILABLE" then 3
              elif .availability == "AVAILABLE" then 2
              elif .availability == "BUSY" then 1
              else 0
              end
            )
          }
        | select(.major >= $minimum_major)
      ]
      | sort_by([
          .model_priority,
          .parsed_os,
          .availability_priority,
          .model
        ])
      | last
    ' "${result_directory}/metadata/devices.json"
)"
readonly selected_device

selected_device_arn="$(jq -r '.arn // empty' <<<"${selected_device}")"
readonly selected_device_arn

if [[ -z "${selected_device_arn}" ]]; then
  echo "错误：Device Farm 当前没有 iOS ${minimum_ios_major} 或更高版本的公共 iPhone。" >&2
  jq \
    '[.devices[] | select(.platform == "IOS" and .formFactor == "PHONE") | {model, os, availability}]' \
    "${result_directory}/metadata/devices.json" >&2
  exit 1
fi

jq \
  '{
    arn,
    name,
    manufacturer,
    model,
    modelId,
    formFactor,
    platform,
    os,
    availability
  }' <<<"${selected_device}" \
  > "${result_directory}/selected-device.json"

echo "已选择真机：$(jq -r '"\(.model) / iOS \(.os) / \(.availability)"' <<<"${selected_device}")"

run_name="VideoToolboxStudio-${GITHUB_RUN_NUMBER:-local}-${GITHUB_SHA:-local}"
run_name="${run_name:0:240}"
readonly run_name

jq -n \
  --arg project_arn "${project_arn}" \
  --arg app_arn "${app_upload_arn}" \
  --arg test_package_arn "${test_upload_arn}" \
  --arg device_arn "${selected_device_arn}" \
  --arg run_name "${run_name}" \
  '{
    projectArn: $project_arn,
    appArn: $app_arn,
    name: $run_name,
    deviceSelectionConfiguration: {
      filters: [
        {
          attribute: "ARN",
          operator: "EQUALS",
          values: [$device_arn]
        }
      ],
      maxDevices: 1
    },
    test: {
      type: "XCTEST_UI",
      testPackageArn: $test_package_arn,
      parameters: {
        app_performance_monitoring: "false"
      }
    },
    configuration: {
      billingMethod: "METERED"
    },
    executionConfiguration: {
      jobTimeoutMinutes: 20,
      accountsCleanup: true,
      appPackagesCleanup: true,
      skipAppResign: false
    }
  }' \
  > "${result_directory}/metadata/run-request.json"

echo "正在调度 AWS Device Farm 真机运行。"
aws devicefarm schedule-run \
  --cli-input-json "file://${result_directory}/metadata/run-request.json" \
  --region "${aws_region}" \
  > "${result_directory}/metadata/run-start.json"

run_arn="$(
  jq -r '.run.arn // empty' \
    "${result_directory}/metadata/run-start.json"
)"
readonly run_arn

if [[ -z "${run_arn}" ]]; then
  echo "错误：Device Farm 未返回 Run ARN。" >&2
  exit 1
fi

run_status=""
run_result=""
for attempt in $(seq 1 120); do
  aws devicefarm get-run \
    --arn "${run_arn}" \
    --region "${aws_region}" \
    > "${result_directory}/metadata/run-current.json"

  run_status="$(jq -r '.run.status // empty' "${result_directory}/metadata/run-current.json")"
  run_result="$(jq -r '.run.result // empty' "${result_directory}/metadata/run-current.json")"
  echo "第 ${attempt} 次查询：状态 ${run_status:-未知}，结果 ${run_result:-未知}"

  if [[ "${run_status}" == "COMPLETED" ]]; then
    break
  fi

  sleep 20
done

cp \
  "${result_directory}/metadata/run-current.json" \
  "${result_directory}/metadata/run-final.json"

aws devicefarm list-jobs \
  --arn "${run_arn}" \
  --region "${aws_region}" \
  > "${result_directory}/metadata/jobs.json"

download_artifacts() {
  local artifact_type="$1"
  local output_subdirectory="$2"
  local raw_metadata
  local public_metadata
  local artifact_index=0

  raw_metadata="$(mktemp)"
  public_metadata="${result_directory}/metadata/artifacts-${artifact_type,,}.json"

  aws devicefarm list-artifacts \
    --arn "${run_arn}" \
    --type "${artifact_type}" \
    --region "${aws_region}" \
    > "${raw_metadata}"

  jq '(.artifacts[]? |= del(.url))' "${raw_metadata}" > "${public_metadata}"

  while IFS=$'\t' read -r artifact_name artifact_extension artifact_url; do
    [[ -n "${artifact_url}" ]] || continue
    artifact_index=$((artifact_index + 1))
    safe_name="$(
      printf '%s' "${artifact_name:-artifact}" \
        | tr -cs '[:alnum:]._-' '_'
    )"
    safe_extension="$(
      printf '%s' "${artifact_extension:-bin}" \
        | tr -cs '[:alnum:]' '_'
    )"
    curl \
      --silent \
      --show-error \
      --fail-with-body \
      "${artifact_url}" \
      > "${result_directory}/artifacts/${output_subdirectory}/$(printf '%03d' "${artifact_index}")-${safe_name}.${safe_extension}"
  done < <(
    jq -r '.artifacts[]? | [.name, .extension, .url] | @tsv' "${raw_metadata}"
  )

  rm -f "${raw_metadata}"
}

echo "正在回收 Device Farm 文件、日志和截图。"
download_artifacts "FILE" "files"
download_artifacts "LOG" "logs"
download_artifacts "SCREENSHOT" "screenshots"

extract_report() {
  local marker="$1"
  local output_path="$2"
  local report_token

  report_token="$(
    grep \
      --binary-files=text \
      --recursive \
      --only-matching \
      "${marker}=[A-Za-z0-9+/=]*" \
      "${result_directory}/artifacts" 2>/dev/null \
      | tail -n 1 \
      | cut -d= -f2- \
      || true
  )"

  if [[ -n "${report_token}" ]]; then
    printf '%s' "${report_token}" \
      | openssl base64 -d -A \
      > "${output_path}"
  fi
}

extract_report \
  "VT_CLOUD_CAPABILITY_REPORT_BASE64" \
  "${result_directory}/capability-summary.json"
extract_report \
  "VT_CLOUD_SUSTAINED_REPORT_BASE64" \
  "${result_directory}/sustained-encoding-summary.json"

jq -n \
  --arg run_arn "${run_arn}" \
  --arg status "${run_status}" \
  --arg result "${run_result}" \
  --slurpfile selected_device "${result_directory}/selected-device.json" \
  --slurpfile jobs "${result_directory}/metadata/jobs.json" \
  '{
    run_arn: $run_arn,
    status: $status,
    result: $result,
    selected_device: $selected_device[0],
    jobs: [
      $jobs[0].jobs[]?
      | {
          arn,
          name,
          type,
          status,
          result,
          message,
          device: {
            name: .device.name,
            model: .device.model,
            os: .device.os,
            platform: .device.platform
          },
          counters,
          deviceMinutes
        }
    ]
  }' \
  > "${result_directory}/run-summary.json"

if [[ "${run_status}" != "COMPLETED" ]]; then
  echo "错误：Device Farm Run 在等待窗口内未完成。" >&2
  exit 1
fi

if [[ "${run_result}" != "PASSED" ]]; then
  echo "错误：Device Farm 真机测试结果为 ${run_result:-未知}。" >&2
  exit 1
fi

if [[ ! -s "${result_directory}/capability-summary.json" ]]; then
  echo "错误：测试通过，但未从 Device Farm 日志回收到能力摘要。" >&2
  exit 1
fi

if [[ ! -s "${result_directory}/sustained-encoding-summary.json" ]]; then
  echo "错误：测试通过，但未从 Device Farm 日志回收到持续硬编摘要。" >&2
  exit 1
fi

echo "AWS Device Farm 真机测试与报告回收全部通过。"
