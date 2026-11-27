#!/usr/bin/env bash
#
# Unit tests for the ibmcloud-snc action. Runs run.sh against a fake podman
# shim that records its arguments and simulates the mapt container writing
# connection details. No cloud, no containers, no network.
#
# Usage: bash ibmcloud-snc/tests/run-tests.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SH="$ROOT/run.sh"

PASS=0
FAIL=0
TMP_ROOT=""

pass() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}
fail_test() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

setup() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/snc-tests.XXXXXX")"
  mkdir -p "$TMP_ROOT/ws" "$TMP_ROOT/rt" "$TMP_ROOT/bin"
  cat >"$TMP_ROOT/bin/podman" <<'EOF'
#!/usr/bin/env bash
# Fake podman: records its arguments and simulates the mapt container.
set -u
printf '%s\n' "$@" >> "${SHIM_LOG:?SHIM_LOG not set}"
if [ "${FAKE_EXIT:-0}" -ne 0 ]; then
  exit "${FAKE_EXIT}"
fi
# Simulate mapt writing connection details into the /workspace mount.
ws=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-v" ]; then
    case "$a" in
      *:/workspace) ws="${a%:/workspace}" ;;
    esac
  fi
  prev="$a"
done
if [ -n "$ws" ] && [ -n "${FAKE_CONN:-}" ]; then
  d="$ws/${CONN_DETAILS_OUTPUT:-snc-conn-details}"
  mkdir -p "$d"
  printf '203.0.113.10\n' > "$d/host"
  printf 'core\n' > "$d/username"
  printf 'FAKE-KEY\n' > "$d/id_rsa"
  printf 'FAKE-KUBECONFIG\n' > "$d/kubeconfig"
fi
exit 0
EOF
  chmod +x "$TMP_ROOT/bin/podman"
  : >"$TMP_ROOT/args"
  : >"$TMP_ROOT/out"
  : >"$TMP_ROOT/env"
}

# run_action [KEY=VALUE ...]: runs run.sh in a clean environment (env -i)
# with a base configuration plus the given KEY=VALUE overrides. Later pairs
# win over earlier ones and over the base. Returns the script exit code.
run_action() {
  env -i \
    PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    GITHUB_WORKSPACE="$TMP_ROOT/ws" \
    RUNNER_TEMP="$TMP_ROOT/rt" \
    GITHUB_RUN_ID=987654321 \
    GITHUB_RUN_ATTEMPT=1 \
    RUNNER_TRACKING_ID=github_0123456789abcdef0123456789abcdef \
    GITHUB_OUTPUT="$TMP_ROOT/out" \
    GITHUB_ENV="$TMP_ROOT/env" \
    IBMCLOUD_API_KEY=test-api-key \
    IC_REGION=us-south \
    IC_ZONE=us-south-1 \
    SHIM_LOG="$TMP_ROOT/args" \
    "$@" \
    bash "$RUN_SH"
}

# arg_after <flag>: prints the argument following the last <flag> in the shim log.
arg_after() {
  awk -v flag="$1" '$0 == flag { getline; print }' "$TMP_ROOT/args" | tail -1
}

assert_rc() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail_test "$1: expected rc $2, got $3"; fi
}
assert_line() { # desc expected-line
  if grep -qFx -- "$2" "$TMP_ROOT/args"; then pass "$1"; else fail_test "$1: podman args missing line [$2]"; fi
}
assert_no_line() { # desc unwanted-line
  if grep -qFx -- "$2" "$TMP_ROOT/args"; then fail_test "$1: podman args should not contain [$2]"; else pass "$1"; fi
}
assert_contains() { # desc needle file
  if grep -qF -- "$2" "$3"; then pass "$1"; else fail_test "$1: [$3] does not contain [$2]"; fi
}
assert_no_podman_call() { # desc
  if [ -s "$TMP_ROOT/args" ]; then fail_test "$1: podman was invoked"; else pass "$1"; fi
}
assert_mode_600() { # desc file
  if [ -n "$(find "$2" -perm 600 2>/dev/null)" ]; then
    pass "$1"
  else
    fail_test "$1: $2 is not mode 600"
  fi
}

# --- tests ------------------------------------------------------------------

test_create_full() {
  echo "create with a full input set"
  setup
  run_action OPERATION=create PROJECT_NAME_INPUT=my-snc \
    BACKED_URL_INPUT=s3://my-bucket VERSION=4.22.14 \
    CPUS=16 MEMORY=96 GPUS=2 GPU_MANUFACTURER=NVIDIA COMPUTE_FAMILIES=bx2,cx2 \
    DISK_SIZE=300 SPOT=true PROFILE=ai,nvidia \
    "OPERATOR_CHANNEL=serverless-operator=preview,nfd=4.17" \
    "CATALOG_SOURCE=serverless-operator=quay.io/org/index:latest" \
    "TAGS=team=gpu,usage=ci" PULL_SECRET='{"auths":{"fake":{"auth":"Zm9vOmJhcgo="}}}' \
    IBMCLOUD_COS_ACCESS_KEY_ID=cos-key IBMCLOUD_COS_SECRET_ACCESS_KEY=cos-secret \
    FAKE_CONN=1 >"$TMP_ROOT/stdout" 2>&1
  rc=$?
  assert_rc "exits 0" 0 "$rc"

  assert_line "runs mapt command" "ibmcloud"
  assert_line "runs snc command" "openshift-snc"
  assert_line "runs create" "create"
  assert_line "project name" "--project-name"
  assert_line "project name value" "my-snc"
  assert_line "backed url flag" "--backed-url"
  assert_line "backed url value" "s3://my-bucket"
  assert_line "conn details output" "--conn-details-output"
  assert_line "conn details value" "/workspace/snc-conn-details"
  assert_line "pull secret flag" "--pull-secret-file"
  assert_line "version flag" "--version"
  assert_line "version value" "4.22.14"
  assert_line "disk size" "--disk-size"
  assert_line "disk size value" "300"
  assert_line "cpus flag" "--cpus"
  assert_line "cpus value" "16"
  assert_line "memory value" "96"
  assert_line "gpus value" "2"
  assert_line "gpu manufacturer" "NVIDIA"
  assert_line "compute families" "bx2,cx2"
  assert_line "spot flag" "--spot"
  assert_line "profile" "ai,nvidia"
  assert_line "operator channel 1" "serverless-operator=preview"
  assert_line "operator channel 2" "nfd=4.17"
  assert_line "catalog source" "serverless-operator=quay.io/org/index:latest"
  assert_line "tags" "team=gpu,usage=ci"
  assert_line "container user" "--user"
  assert_line "entrypoint" "--entrypoint"
  assert_line "entrypoint value" "mapt"
  assert_line "pinned image" "quay.io/redhat-developer/mapt:v0.14.7"
  assert_line "forwards COS access key" "IBMCLOUD_COS_ACCESS_KEY_ID"
  assert_no_line "no nested-virt" "--nested-virt"
  assert_no_line "no vpc-id" "--vpc-id"

  assert_contains "outputs host" "host=203.0.113.10" "$TMP_ROOT/out"
  assert_contains "outputs username" "username=core" "$TMP_ROOT/out"
  assert_contains "outputs id-rsa" "id-rsa=$TMP_ROOT/ws/snc-conn-details/id_rsa" "$TMP_ROOT/out"
  assert_contains "outputs kubeconfig" "kubeconfig=$TMP_ROOT/ws/snc-conn-details/kubeconfig" "$TMP_ROOT/out"
  assert_contains "outputs conn-details" "conn-details=$TMP_ROOT/ws/snc-conn-details" "$TMP_ROOT/out"
  assert_contains "outputs project-name" "project-name=my-snc" "$TMP_ROOT/out"
  assert_contains "exports KUBECONFIG" "KUBECONFIG=$TMP_ROOT/ws/snc-conn-details/kubeconfig" "$TMP_ROOT/env"

  assert_mode_600 "id_rsa is mode 600" "$TMP_ROOT/ws/snc-conn-details/id_rsa"
  assert_mode_600 "kubeconfig is mode 600" "$TMP_ROOT/ws/snc-conn-details/kubeconfig"
  if [ -z "$(ls -A "$TMP_ROOT/rt")" ]; then
    pass "pull secret temp file removed"
  else
    fail_test "RUNNER_TEMP still holds: $(ls -A "$TMP_ROOT/rt")"
  fi
  if grep -qF 'test-api-key' "$TMP_ROOT/args" || grep -qF 'test-api-key' "$TMP_ROOT/stdout"; then
    fail_test "API key leaked into args or output"
  else
    pass "API key not leaked"
  fi
  if grep -qF 'Zm9vOmJhcgo' "$TMP_ROOT/args" || grep -qF 'Zm9vOmJhcgo' "$TMP_ROOT/stdout"; then
    fail_test "pull secret leaked into args or output"
  else
    pass "pull secret not leaked"
  fi
}

test_create_defaults() {
  echo "create with defaults"
  setup
  run_action OPERATION=create PULL_SECRET=pull-secret-content FAKE_CONN=1 \
    >/dev/null 2>&1
  assert_rc "exits 0" 0 "$?"

  # snc-<run id>-<attempt>-<tracking suffix, sanitized and cut to 12>
  assert_line "default project name" "snc-987654321-1-0123456789ab"
  assert_line "default backed url" "file:///workspace/.mapt"
  assert_line "default disk size" "200"
  assert_line "default cpus" "8"
  assert_line "default memory" "64"
  assert_line "default gpus" "0"
  assert_line "default image" "quay.io/redhat-developer/mapt:v0.14.7"
  if [ -d "$TMP_ROOT/ws/.mapt" ]; then
    pass "creates local state dir"
  else
    fail_test "local state dir not created"
  fi
}

test_project_name_stability() {
  echo "default project name is stable within a job, unique per job"
  setup
  run_action OPERATION=create PULL_SECRET=x >/dev/null 2>&1
  name1="$(arg_after --project-name)"
  run_action OPERATION=create PULL_SECRET=x >/dev/null 2>&1
  name2="$(arg_after --project-name)"
  run_action OPERATION=create PULL_SECRET=x RUNNER_TRACKING_ID=github_ffffffffffffffffffffffffffffffff \
    >/dev/null 2>&1
  name3="$(arg_after --project-name)"

  if [ -n "$name1" ] && [ "$name1" = "$name2" ]; then
    pass "same job env gives same name ($name1)"
  else
    fail_test "names differ within one job: [$name1] vs [$name2]"
  fi
  if [ -n "$name1" ] && [ "$name1" != "$name3" ]; then
    pass "different job gives different name ($name3)"
  else
    fail_test "names collide across jobs: [$name1] vs [$name3]"
  fi
  assert_contains "project-name output matches arg" "project-name=$name1" "$TMP_ROOT/out"
}

test_destroy() {
  echo "destroy"
  setup
  run_action OPERATION=destroy PROJECT_NAME_INPUT=my-snc FORCE_DESTROY=true KEEP_STATE=true \
    >/dev/null 2>&1
  assert_rc "exits 0 without zone or pull secret" 0 "$?"
  assert_line "runs destroy" "destroy"
  assert_line "force destroy" "--force-destroy"
  assert_line "keep state" "--keep-state"
  assert_line "project name" "my-snc"
  assert_no_line "no pull secret flag" "--pull-secret-file"
  assert_no_line "no conn details flag" "--conn-details-output"
  assert_contains "project-name output" "project-name=my-snc" "$TMP_ROOT/out"
}

test_failed_create() {
  echo "failed create still exports project name and cleans up"
  setup
  run_action OPERATION=create PULL_SECRET=pull-secret-content FAKE_EXIT=1 \
    >"$TMP_ROOT/stdout" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then pass "exits non-zero"; else fail_test "expected failure, got 0"; fi
  assert_contains "project-name exported before failure" "project-name=snc-987654321-1-0123456789ab" "$TMP_ROOT/out"
  if [ -z "$(ls -A "$TMP_ROOT/rt")" ]; then
    pass "pull secret temp file removed after failure"
  else
    fail_test "RUNNER_TEMP still holds: $(ls -A "$TMP_ROOT/rt")"
  fi
}

expect_failure() { # desc message [KEY=VALUE ...]
  local desc="$1" message="$2"
  shift 2
  setup
  run_action "$@" >"$TMP_ROOT/stdout" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then pass "$desc: exits non-zero"; else fail_test "$desc: expected failure, got 0"; fi
  assert_contains "$desc: error message mentions '$message'" "$message" "$TMP_ROOT/stdout"
  assert_no_podman_call "$desc: podman not invoked"
}

test_validation() {
  echo "input validation"

  expect_failure "bad operation" "operation must be" \
    OPERATION=upgrade
  expect_failure "bad boolean" "must be 'true' or 'false'" \
    OPERATION=create SPOT=maybe PULL_SECRET=x
  expect_failure "both pull secret inputs" "not both" \
    OPERATION=create PULL_SECRET=x PULL_SECRET_FILE=/etc/hosts
  expect_failure "nested-virt with spot" "mutually exclusive" \
    OPERATION=create NESTED_VIRT=true SPOT=true PULL_SECRET=x
  expect_failure "azblob backend" "not supported" \
    OPERATION=create BACKED_URL_INPUT=azblob://bucket PULL_SECRET=x
  expect_failure "unknown backend scheme" "must start with" \
    OPERATION=create BACKED_URL_INPUT=gcs://bucket PULL_SECRET=x
  expect_failure "cos backend without credentials" "IBMCLOUD_COS_ACCESS_KEY_ID" \
    OPERATION=create BACKED_URL_INPUT=cos://bucket PULL_SECRET=x
  expect_failure "non-numeric cpus" "must be an integer" \
    OPERATION=create CPUS=eight PULL_SECRET=x
  expect_failure "zero cpus" "must be an integer" \
    OPERATION=create CPUS=0 PULL_SECRET=x
  expect_failure "missing region" "region is required" \
    OPERATION=create IC_REGION= PULL_SECRET=x
  expect_failure "missing zone on create" "zone is required" \
    OPERATION=create PULL_SECRET=x IC_ZONE=
  expect_failure "missing pull secret" "pull-secret (content) or pull-secret-file" \
    OPERATION=create
  expect_failure "missing API key" "IBMCLOUD_API_KEY is not set" \
    OPERATION=create IBMCLOUD_API_KEY= PULL_SECRET=x
  expect_failure "vpc-id with pinned image" "vpc-id requires" \
    OPERATION=create VPC_ID=r134-xx PULL_SECRET=x
  expect_failure "bad operator-channel item" "invalid operator-channel item" \
    OPERATION=create "OPERATOR_CHANNEL=noequalsign" PULL_SECRET=x
  expect_failure "empty pull secret" "pull secret is empty" \
    OPERATION=create PULL_SECRET=" "
}

test_vpc_id_with_dev_image() {
  echo "vpc-id allowed with a non-default image"
  setup
  run_action OPERATION=create PULL_SECRET=x VPC_ID=r134-xx FAKE_CONN=1 \
    MAPT_IMAGE=quay.io/redhat-developer/mapt:v1.0.0-dev \
    >/dev/null 2>&1
  assert_rc "exits 0" 0 "$?"
  assert_line "vpc id flag" "--vpc-id"
  assert_line "vpc id value" "r134-xx"
}

# --- run --------------------------------------------------------------------

test_create_full
test_create_defaults
test_project_name_stability
test_destroy
test_failed_create
test_validation
test_vpc_id_with_dev_image

echo
echo "passed: $PASS, failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
