#!/usr/bin/env bash
#
# Create or destroy a single-node OpenShift (SNC) cluster on IBM Cloud by
# running the mapt OCI image. Invoked by action.yml, which maps the action
# inputs to environment variables. Also runnable directly (tests, local use).
#
# State backends supported by the mapt ibmcloud provider:
#   file://...     local state, inside the container /workspace mount
#   cos://bucket   IBM Cloud Object Storage
#   s3://bucket    also IBM Cloud Object Storage (mapt maps it to COS)
set -euo pipefail

fail() {
  echo "::error::$*"
  exit 1
}

log() {
  echo "[ibmcloud-snc] $*"
}

# --- helpers ---------------------------------------------------------------

# bool_input <input-name> <value>: prints "true"/"false", or exits non-zero.
bool_input() {
  local value
  value="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true | false) printf '%s' "$value" ;;
    *)
      echo "input '$1' must be 'true' or 'false' (got '${2:-}')" >&2
      exit 1
      ;;
  esac
}

# int_input <input-name> <value> <min>: prints value, or exits non-zero.
int_input() {
  local value="${2:-}" min="$3"
  case "$value" in
    '' | *[!0-9]*)
      echo "input '$1' must be an integer >= $min (got '$value')" >&2
      exit 1
      ;;
  esac
  if [ "$value" -lt "$min" ]; then
    echo "input '$1' must be an integer >= $min (got '$value')" >&2
    exit 1
  fi
  printf '%s' "$value"
}

# --- normalize and validate ------------------------------------------------

OPERATION="${OPERATION:-create}"
case "$OPERATION" in
  create | destroy) ;;
  *) fail "operation must be 'create' or 'destroy' (got '$OPERATION')" ;;
esac

SPOT="$(bool_input spot "${SPOT:-false}")" || fail "invalid 'spot' input"
NESTED_VIRT="$(bool_input nested-virt "${NESTED_VIRT:-false}")" || fail "invalid 'nested-virt' input"
DISABLE_CLUSTER_READINESS="$(bool_input disable-cluster-readiness "${DISABLE_CLUSTER_READINESS:-false}")" || fail "invalid 'disable-cluster-readiness' input"
DEBUG="$(bool_input debug "${DEBUG:-false}")" || fail "invalid 'debug' input"
FORCE_DESTROY="$(bool_input force-destroy "${FORCE_DESTROY:-false}")" || fail "invalid 'force-destroy' input"
KEEP_STATE="$(bool_input keep-state "${KEEP_STATE:-false}")" || fail "invalid 'keep-state' input"

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then
  fail "IBMCLOUD_API_KEY is not set. Pass it on the step env from a GitHub secret."
fi

if [ -z "${GITHUB_WORKSPACE:-}" ]; then
  fail "GITHUB_WORKSPACE is not set"
fi
RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$RUNNER_TEMP"

# Region and zone: inputs take precedence over the environment.
if [ -n "${REGION_INPUT:-}" ]; then export IC_REGION="$REGION_INPUT"; fi
if [ -n "${ZONE_INPUT:-}" ]; then export IC_ZONE="$ZONE_INPUT"; fi
if [ -z "${IC_REGION:-}" ]; then
  fail "IBM Cloud region is required: set the 'region' input or the IC_REGION environment variable"
fi
if [ "$OPERATION" = "create" ] && [ -z "${IC_ZONE:-}" ]; then
  fail "IBM Cloud zone is required for create: set the 'zone' input or the IC_ZONE environment variable"
fi

if [ "$NESTED_VIRT" = "true" ] && [ "$SPOT" = "true" ]; then
  fail "nested-virt and spot are mutually exclusive: a bare metal server takes no spot capacity"
fi

MAPT_IMAGE="${MAPT_IMAGE:-quay.io/redhat-developer/mapt:v0.14.7}"
if [ -n "${VPC_ID:-}" ] && [ "$MAPT_IMAGE" = "quay.io/redhat-developer/mapt:v0.14.7" ]; then
  # TODO: remove this guard when a mapt release ships --vpc-id (main only at
  # v0.14.7) and the default image is bumped past it.
  fail "vpc-id requires a mapt image that supports --vpc-id (not in v0.14.7). Set mapt-image to a newer tag (e.g. quay.io/redhat-developer/mapt:v1.0.0-dev) or unset vpc-id"
fi

# --- project name ----------------------------------------------------------

# Default: unique per job execution (concurrent runs, matrix legs, re-runs)
# but stable across the steps of one job, so create and destroy agree.
default_project_name() {
  local name="snc-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}"
  if [ -n "${RUNNER_TRACKING_ID:-}" ]; then
    local suffix
    suffix="${RUNNER_TRACKING_ID##*_}"
    suffix="$(printf '%s' "$suffix" | tr -c 'a-zA-Z0-9' '-' | cut -c1-12)"
    name="${name}-${suffix}"
  fi
  printf '%s' "$name"
}
PROJECT_NAME="${PROJECT_NAME_INPUT:-$(default_project_name)}"

# Export the project name before touching the cloud, so a partially failed
# create can still be destroyed using the same output.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "project-name=${PROJECT_NAME}" >>"$GITHUB_OUTPUT"
fi

# --- state backend ---------------------------------------------------------

if [ -n "${BACKED_URL_INPUT:-}" ]; then
  BACKED_URL="$BACKED_URL_INPUT"
  case "$BACKED_URL" in
    file://* | cos://* | s3://*) ;;
    azblob://*)
      fail "azblob:// is not supported by the mapt ibmcloud provider. Use cos://<bucket> (IBM Cloud Object Storage)."
      ;;
    *)
      fail "backed-url must start with file://, cos:// or s3:// (got '$BACKED_URL')"
      ;;
  esac
  case "$BACKED_URL" in
    cos://* | s3://*)
      if [ -z "${IBMCLOUD_COS_ACCESS_KEY_ID:-}" ] || [ -z "${IBMCLOUD_COS_SECRET_ACCESS_KEY:-}" ]; then
        fail "cos:// and s3:// backends (both IBM Cloud Object Storage) need IBMCLOUD_COS_ACCESS_KEY_ID and IBMCLOUD_COS_SECRET_ACCESS_KEY on the step env"
      fi
      ;;
  esac
else
  BACKED_URL="file:///workspace/.mapt"
  mkdir -p "${GITHUB_WORKSPACE}/.mapt"
fi

# --- pull secret (create only) ---------------------------------------------

PULL_SECRET_TMP=""
cleanup() {
  if [ -n "$PULL_SECRET_TMP" ] && [ -f "$PULL_SECRET_TMP" ]; then
    rm -f "$PULL_SECRET_TMP"
  fi
}
trap cleanup EXIT

if [ "$OPERATION" = "create" ]; then
  if [ -n "${PULL_SECRET:-}" ] && [ -n "${PULL_SECRET_FILE:-}" ]; then
    fail "set either pull-secret or pull-secret-file, not both"
  fi
  PULL_SECRET_TMP="$(mktemp "${RUNNER_TEMP}/snc-pull-secret.XXXXXX")"
  if [ -n "${PULL_SECRET:-}" ]; then
    printf '%s' "$PULL_SECRET" >"$PULL_SECRET_TMP"
  elif [ -n "${PULL_SECRET_FILE:-}" ]; then
    if [ ! -s "$PULL_SECRET_FILE" ]; then
      fail "pull-secret-file '$PULL_SECRET_FILE' is missing or empty"
    fi
    cp -f "$PULL_SECRET_FILE" "$PULL_SECRET_TMP"
  else
    fail "pull-secret (content) or pull-secret-file (path) is required for create"
  fi
  chmod 600 "$PULL_SECRET_TMP"
  if [ -z "$(tr -d '[:space:]' <"$PULL_SECRET_TMP")" ]; then
    fail "the pull secret is empty"
  fi
fi

# --- build the mapt command line -------------------------------------------

args=(ibmcloud openshift-snc "$OPERATION"
  --project-name "$PROJECT_NAME"
  --backed-url "$BACKED_URL")

if [ "$DEBUG" = "true" ]; then
  args+=(--debug)
fi

if [ "$OPERATION" = "create" ]; then
  CPUS="$(int_input cpus "${CPUS:-8}" 1)" || fail "invalid 'cpus' input"
  MEMORY="$(int_input memory "${MEMORY:-64}" 1)" || fail "invalid 'memory' input"
  GPUS="$(int_input gpus "${GPUS:-0}" 0)" || fail "invalid 'gpus' input"
  DISK_SIZE="$(int_input disk-size "${DISK_SIZE:-200}" 1)" || fail "invalid 'disk-size' input"

  args+=(--conn-details-output "/workspace/${CONN_DETAILS_OUTPUT:-snc-conn-details}"
    --pull-secret-file "/runner-temp/$(basename "$PULL_SECRET_TMP")"
    --disk-size "$DISK_SIZE")

  if [ -n "${VERSION:-}" ]; then args+=(--version "$VERSION"); fi
  if [ -n "${VPC_ID:-}" ]; then args+=(--vpc-id "$VPC_ID"); fi
  if [ -n "${COMPUTE_SIZES:-}" ]; then
    args+=(--compute-sizes "$COMPUTE_SIZES")
  else
    args+=(--cpus "$CPUS" --memory "$MEMORY" --gpus "$GPUS")
    if [ -n "${GPU_MANUFACTURER:-}" ]; then args+=(--gpu-manufacturer "$GPU_MANUFACTURER"); fi
    if [ -n "${COMPUTE_FAMILIES:-}" ]; then args+=(--compute-families "$COMPUTE_FAMILIES"); fi
  fi
  if [ "$NESTED_VIRT" = "true" ]; then args+=(--nested-virt); fi
  if [ "$SPOT" = "true" ]; then args+=(--spot); fi
  if [ "$DISABLE_CLUSTER_READINESS" = "true" ]; then args+=(--disable-cluster-readiness); fi
  if [ -n "${PROFILE:-}" ]; then args+=(--profile "$PROFILE"); fi
  if [ -n "${OPERATOR_CHANNEL:-}" ]; then
    IFS=',' read -ra channels <<<"$OPERATOR_CHANNEL"
    for ch in "${channels[@]}"; do
      case "$ch" in
        *=*) args+=(--operator-channel "$ch") ;;
        *) fail "invalid operator-channel item '$ch' (expected package=channel)" ;;
      esac
    done
  fi
  if [ -n "${CATALOG_SOURCE:-}" ]; then
    IFS=',' read -ra sources <<<"$CATALOG_SOURCE"
    for cs in "${sources[@]}"; do
      case "$cs" in
        *=*) args+=(--catalog-source "$cs") ;;
        *) fail "invalid catalog-source item '$cs' (expected package=index-image)" ;;
      esac
    done
  fi
  if [ -n "${TAGS:-}" ]; then args+=(--tags "$TAGS"); fi
else
  if [ "$FORCE_DESTROY" = "true" ]; then args+=(--force-destroy); fi
  if [ "$KEEP_STATE" = "true" ]; then args+=(--keep-state); fi
fi

# --- run the mapt container ------------------------------------------------

CTR="$(command -v podman || command -v docker)" ||
  fail "neither podman nor docker found on the runner"

ctr_env=(-e IBMCLOUD_API_KEY -e IC_REGION)
if [ -n "${IC_ZONE:-}" ]; then
  ctr_env+=(-e IC_ZONE)
fi
for v in IBMCLOUD_COS_ACCESS_KEY_ID IBMCLOUD_COS_SECRET_ACCESS_KEY IBMCLOUD_COS_ENDPOINT; do
  if [ -n "${!v:-}" ]; then
    ctr_env+=(-e "$v")
  fi
done

log "${OPERATION} stack '${PROJECT_NAME}' with ${MAPT_IMAGE}"
"${CTR}" run --rm \
  --user 0 \
  --entrypoint mapt \
  -v "${GITHUB_WORKSPACE}":/workspace \
  -v "${RUNNER_TEMP}":/runner-temp \
  "${ctr_env[@]}" \
  "${MAPT_IMAGE}" \
  "${args[@]}"

# --- post-process the connection details (create only) ---------------------

if [ "$OPERATION" = "create" ]; then
  CONN_DIR_HOST="${GITHUB_WORKSPACE}/${CONN_DETAILS_OUTPUT:-snc-conn-details}"
  for f in host username id_rsa; do
    if [ ! -s "${CONN_DIR_HOST}/${f}" ]; then
      fail "mapt did not produce ${CONN_DIR_HOST}/${f}"
    fi
  done

  # The mapt container may have written the files as root (docker fallback):
  # hand everything to the runner user, then restrict the sensitive files.
  chown -R "$(id -u):$(id -g)" "$CONN_DIR_HOST" 2>/dev/null ||
    sudo chown -R "$(id -u):$(id -g)" "$CONN_DIR_HOST"
  if [ -d "${GITHUB_WORKSPACE}/.mapt" ]; then
    chown -R "$(id -u):$(id -g)" "${GITHUB_WORKSPACE}/.mapt" 2>/dev/null ||
      sudo chown -R "$(id -u):$(id -g)" "${GITHUB_WORKSPACE}/.mapt"
  fi
  chmod 600 "$CONN_DIR_HOST/id_rsa"
  if [ -f "$CONN_DIR_HOST/kubeconfig" ]; then chmod 600 "$CONN_DIR_HOST/kubeconfig"; fi
  if [ -f "$CONN_DIR_HOST/kubeadmin_pass" ]; then chmod 600 "$CONN_DIR_HOST/kubeadmin_pass"; fi

  if [ "$DISABLE_CLUSTER_READINESS" != "true" ] && [ ! -s "${CONN_DIR_HOST}/kubeconfig" ]; then
    fail "mapt did not produce ${CONN_DIR_HOST}/kubeconfig"
  fi
  if [ -s "${CONN_DIR_HOST}/kubeconfig" ] && [ -n "${GITHUB_ENV:-}" ]; then
    echo "KUBECONFIG=${CONN_DIR_HOST}/kubeconfig" >>"$GITHUB_ENV"
  fi

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    HOST="$(tr -d '[:space:]' <"${CONN_DIR_HOST}/host")"
    USERNAME="$(tr -d '[:space:]' <"${CONN_DIR_HOST}/username")"
    {
      echo "host=${HOST}"
      echo "username=${USERNAME}"
      echo "id-rsa=${CONN_DIR_HOST}/id_rsa"
      if [ -s "${CONN_DIR_HOST}/kubeconfig" ]; then
        echo "kubeconfig=${CONN_DIR_HOST}/kubeconfig"
      fi
      echo "conn-details=${CONN_DIR_HOST}"
    } >>"$GITHUB_OUTPUT"
  fi
fi

log "done"
