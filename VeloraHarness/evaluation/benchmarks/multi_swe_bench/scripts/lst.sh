#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/home/ubuntu/Velora_SWE_Harness/VeloraHarness"
OPENHANDS_DIR="$BASE_DIR/openhands"
DATASETS_DIR="$BASE_DIR/data/datasets"
DATASET_WORK_DIR="$DATASETS_DIR/_tmp_openhands"
RUN_INFER="$BASE_DIR/evaluation/benchmarks/multi_swe_bench/run_infer.py"
EVAL_SCRIPT="$BASE_DIR/evaluation/benchmarks/multi_swe_bench/scripts/eval_pilot2_standardized.py"

OUTPUT_BASE="$BASE_DIR/final_Output"
INSTANCE_LOG_BASE="$BASE_DIR/logs/instancelog"
TMP_DIR="/tmp"

MAX_ITERATIONS="900"
TIMEOUT="900"
EVAL_NOTE="conan_modified_without_browsing"

DRY_RUN=false
LLM_CONFIGS=()

usage() {
  cat <<'EOF'
Usage:
  ./run_conan_8.sh [--dry-run] --llm-config <config> [--llm-config <config> ...]

Examples:
  ./run_conan_8.sh --dry-run --llm-config llm.gemini --llm-config llm.gpt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --llm-config)
      if [[ -z "${2:-}" ]]; then
        echo "Missing value for --llm-config" >&2
        exit 1
      fi
      LLM_CONFIGS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ${#LLM_CONFIGS[@]} -eq 0 ]]; then
  echo "At least one --llm-config is required" >&2
  usage
  exit 1
fi

run_cmd() {
  local -a cmd=("$@")
  printf 'Running:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  if $DRY_RUN; then
    return 0
  fi
  "${cmd[@]}"
}

run_cmd_shell() {
  local cmd="$1"
  echo "Running: ${cmd}"
  if $DRY_RUN; then
    return 0
  fi
  bash -c "$cmd"
}

get_site_packages() {
  (cd "$OPENHANDS_DIR" && poetry run python -c "import site; print(site.getsitepackages()[0])")
}

find_model_dir() {
  local dataset_dir="$1"
  local run_note="$2"
  local pattern="*maxiter_${MAX_ITERATIONS}_N_${run_note}"
  local match
  match=$(ls -dt "$dataset_dir"/$pattern 2>/dev/null | head -1 || true)
  if [[ -z "$match" ]]; then
    echo "No model dir found under $dataset_dir for $run_note" >&2
    return 1
  fi
  echo "$match"
}

get_llm_folder_name() {
  local llm_config="$1"
  echo "${llm_config##*.}"
}

prepare_dataset_for_openhands() {
  local dataset_file="$1"
  local openhands_instance_id="$2"

  if $DRY_RUN; then
    echo "$dataset_file"
    return 0
  fi
  if [[ ! -f "$dataset_file" ]]; then
    echo "Dataset file not found: $dataset_file" >&2
    return 1
  fi

  local current_id
  current_id=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('instance_id',''))" "$dataset_file")
  if [[ "$current_id" == "$openhands_instance_id" ]]; then
    echo "$dataset_file"
    return 0
  fi

  mkdir -p "$DATASET_WORK_DIR"
  local temp_file="$DATASET_WORK_DIR/${openhands_instance_id}.jsonl"
  python3 - <<PY
import json
with open("$dataset_file","r") as f:
    data = json.loads(f.read())
data["instance_id"] = "$openhands_instance_id"
with open("$temp_file","w") as f:
    f.write(json.dumps(data))
PY
  echo "$temp_file"
}

get_image_storage_uri() {
  local dataset_file="$1"
  python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('image_storage_uri',''))" "$dataset_file"
}

download_from_s3() {
  local s3_uri="$1"
  local local_path="$2"
  run_cmd aws s3 cp "$s3_uri" "$local_path" --no-sign-request
}

load_docker_image() {
  local tar_path="$1"
  if $DRY_RUN; then
    echo "<loaded_image>"
    return 0
  fi
  local output
  output=$(docker load < "$tar_path")
  echo "Docker load output: ${output}" >&2
  if [[ "$output" =~ Loaded[[:space:]]image:[[:space:]](.+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$output" =~ Loaded[[:space:]]image[[:space:]]ID:[[:space:]]sha256:([a-f0-9]+) ]]; then
    echo "sha256:${BASH_REMATCH[1]}"
    return 0
  fi
  echo "Could not parse loaded image name from: ${output}" >&2
  return 1
}

if $DRY_RUN; then
  site_packages="<poetry-site-packages>"
else
  site_packages="$(get_site_packages)"
fi

export DOCKER_BUILDKIT="0"
export EVAL_DOCKER_IMAGE_PREFIX="mswebench/"
export USE_INSTANCE_IMAGE="true"
export LANGUAGE="python"
export RUN_WITH_BROWSING="false"
export PYTHONPATH="${site_packages}:${BASE_DIR}"

mkdir -p "$OUTPUT_BASE" "$INSTANCE_LOG_BASE"

for dataset_path in "$DATASETS_DIR"/1769925655665409.jsonl; do
  [[ -f "$dataset_path" ]] || continue
  instance_id="$(basename "$dataset_path" .jsonl)"
  dataset_file="$DATASETS_DIR/${instance_id}.jsonl"

  if ! $DRY_RUN && [[ ! -f "$dataset_file" ]]; then
    echo "Dataset file not found: $dataset_file" >&2
    exit 1
  fi

  if $DRY_RUN; then
    s3_uri="<s3://bucket/path/to/image.tar>"
  else
    s3_uri="$(get_image_storage_uri "$dataset_file")"
    if [[ -z "$s3_uri" ]]; then
      echo "No image_storage_uri found in $dataset_file" >&2
      exit 1
    fi
  fi

  openhands_instance_id="$instance_id"
  docker_image="mswebench/sweb.eval.x86_64.${instance_id}:latest"

  tar_filename="$(basename "$s3_uri")"
  if $DRY_RUN; then
    tar_filename="image.tar"
  fi
  local_tar="${TMP_DIR}/${tar_filename}"

  echo ""
  echo "============================================================"
  echo "Processing instance: ${instance_id}"
  echo "S3 URI: ${s3_uri}"
  echo "Local tar: ${local_tar}"
  echo "Target image: ${docker_image}"
  echo "============================================================"
  echo ""

  download_from_s3 "$s3_uri" "$local_tar"

  source_image="$(load_docker_image "$local_tar")"
  echo "Loaded image: ${source_image}"

  run_cmd docker tag "$source_image" "$docker_image"

  if ! $DRY_RUN && [[ -f "$local_tar" ]]; then
    echo "Removing tar file: ${local_tar}"
    rm -f "$local_tar"
  fi

  dataset_file_for_openhands="$(prepare_dataset_for_openhands "$dataset_file" "$openhands_instance_id")"
  if $DRY_RUN; then
    echo "Dry-run: OpenHands will use instance_id ${openhands_instance_id}"
  fi

  dataset_desc="${dataset_file_for_openhands//\//__}-train"
  dataset_root="$BASE_DIR/dataset_desc"
  dataset_dir="$dataset_root/$dataset_desc/CodeActAgent"

  for llm_config in "${LLM_CONFIGS[@]}"; do
    llm_folder="$(get_llm_folder_name "$llm_config")"
    for idx in 1; do
      idx_padded="$(printf "%02d" "$idx")"
      run_id="run_${idx_padded}"
      run_note="${EVAL_NOTE}_run_${idx_padded}"
      run_dir="$OUTPUT_BASE/$instance_id/$llm_folder/$run_id"

      echo ""
      echo "=== ${instance_id} | ${llm_config} | Trajectory run ${run_id} ==="

      run_cmd_shell "cd \"$OPENHANDS_DIR\" && poetry run python \"$RUN_INFER\" --agent-cls CodeActAgent --llm-config \"$llm_config\" --max-iterations \"$MAX_ITERATIONS\" --eval-num-workers 1 --eval-n-limit 1 --dataset \"$dataset_file_for_openhands\" --split train --eval-note \"$run_note\" --eval-output-dir \"$dataset_root\""

      if $DRY_RUN; then
        model_dir="${dataset_dir}/<model_dir>"
        echo "Trajectory: ${run_dir}/output.jsonl"
        echo "Eval output: ${run_dir}/eval_output.jsonl"
      else
        model_dir="$(find_model_dir "$dataset_dir" "$run_note")"
        mkdir -p "$(dirname "$run_dir")"
        if [[ -d "$run_dir" ]]; then
          if [[ -n "$(ls -A "$run_dir")" ]]; then
            echo "Run directory not empty: $run_dir" >&2
            exit 1
          fi
          rmdir "$run_dir"
        fi
        mv "$model_dir" "$run_dir"
        model_dir="$run_dir"

        model_parent="$(dirname "$model_dir")"
        if [[ -d "$model_parent" ]] && [[ -z "$(ls -A "$model_parent")" ]]; then
          rmdir "$model_parent" || true
        fi

        dataset_parent="$(dirname "$dataset_dir")"
        if [[ -d "$dataset_parent" ]] && [[ -z "$(ls -A "$dataset_parent")" ]]; then
          rmdir "$dataset_parent" || true
        fi

        echo "Trajectory: ${run_dir}/output.jsonl"
        echo "Eval output: ${run_dir}/eval_output.jsonl"
      fi

      trajectory_file="${run_dir}/output.jsonl"
      eval_output_file="${run_dir}/eval_output.jsonl"

      echo "Trajectory: ${trajectory_file}"
      echo "Eval output: ${eval_output_file}"

      eval_log_dir="${INSTANCE_LOG_BASE}/${instance_id}/${run_id}/evallogs"
      eval_log_file="${eval_log_dir}/eval.log"
      if $DRY_RUN; then
        echo "Eval log: ${eval_log_file}"
        eval_rc=0
      else
        mkdir -p "$eval_log_dir"
        eval_cmd=(
          python3 "$EVAL_SCRIPT"
          --trajectory-file "$trajectory_file"
          --dataset-file "$dataset_file_for_openhands"
          --docker-image "$docker_image"
          --output-file "$eval_output_file"
          --timeout "$TIMEOUT"
        )
        printf 'Running:'
        printf ' %q' "${eval_cmd[@]}"
        printf '\n'
        if "${eval_cmd[@]}" >"$eval_log_file" 2>&1; then
          eval_rc=0
        else
          eval_rc=$?
        fi

        evals_report_dir="${model_dir}/evals_report"
        mkdir -p "$evals_report_dir"
        eval_cmd_str="$(printf '%q ' "${eval_cmd[@]}")"
        {
          echo "# Evaluation script that was run"
          echo "${eval_cmd_str% }"
        } > "${evals_report_dir}/eval.sh"
        if [[ -f "$eval_log_file" ]]; then
          cp "$eval_log_file" "${evals_report_dir}/run_instance.log"
        fi
      fi

      if [[ "${eval_rc}" -ne 0 ]]; then
        echo "Eval for ${instance_id} ${llm_config} ${run_id} exited with ${eval_rc}; continuing to next run."
      fi
    done
  done

  if ! $DRY_RUN; then
    echo ""
    echo "Cleaning up docker images for ${instance_id}..."
    run_cmd_shell "docker rmi \"$docker_image\" || true"
    if [[ -n "${source_image:-}" && "${source_image}" != "<loaded_image>" ]]; then
      run_cmd_shell "docker rmi \"$source_image\" || true"
    fi
    run_cmd_shell "docker system prune -a -f || true"
  fi
done
