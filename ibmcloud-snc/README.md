# OpenShift SNC on IBM Cloud

This action creates or destroys a single-node OpenShift cluster on IBM Cloud VPC, using
[mapt](https://github.com/redhat-developer/mapt) and bundles from the
[SNC](https://github.com/crc-org/snc) project. The compute resource is created from a catalog
image and gets a floating IP for direct SSH and Kubernetes API access. This is not intended for
production use.

## Prerequisite

A catalog image must exist in an IBM Cloud private catalog, generated from the SNC bundle with
[`cloud-importer`](https://github.com/devtools-qe-incubator/cloud-importer). The image must be
named `openshift-local-<version>-<arch>` (e.g. `openshift-local-4-22-14-x86-64`) for mapt's
auto-discovery to work. See the
[mapt documentation](https://github.com/redhat-developer/mapt/blob/main/docs/ibmcloud/openshift-snc.md)
for details.

## Usage

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Create SNC cluster
        id: snc
        uses: mapt-oss/mapt-github-action/ibmcloud-snc@v1
        with:
          region: us-south
          zone: us-south-1
          pull-secret: ${{ secrets.OPENSHIFT_PULL_SECRET }}
        env:
          IBMCLOUD_API_KEY: ${{ secrets.IBMCLOUD_API_KEY }}

      - name: Use the cluster
        run: |
          ssh -i "${{ steps.snc.outputs.id-rsa }}" \
              -o StrictHostKeyChecking=no \
              "${{ steps.snc.outputs.username }}@${{ steps.snc.outputs.host }}" 'hostname'

      - name: Destroy SNC cluster
        if: always()
        uses: mapt-oss/mapt-github-action/ibmcloud-snc@v1
        with:
          operation: destroy
          project-name: ${{ steps.snc.outputs.project-name }}
          region: us-south
        env:
          IBMCLOUD_API_KEY: ${{ secrets.IBMCLOUD_API_KEY }}
```

The action sets `KUBECONFIG` for the subsequent steps of the job, so any step after a successful
create can run `oc` / `kubectl` directly (the client must be installed separately, e.g. with
`redhat-actions/oc-installer`).

Always pair a create with a destroy guarded by `if: always()`, as above: the IBM Cloud resources
outlive the job, and a bare metal server is expensive.

## Failure-safe cleanup

The `project-name` output is exported **before** provisioning starts. If the create fails after
resources exist (partial provisioning, timeout), the destroy step can still identify and remove
the stack, because it runs in the same job and reads `steps.snc.outputs.project-name`.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `IBMCLOUD_API_KEY` | yes | IBM Cloud API key. Pass it from a secret on the step `env`. |
| `IC_REGION` | see `region` | IBM Cloud region. The `region` input takes precedence. |
| `IC_ZONE` | see `zone` | IBM Cloud availability zone. The `zone` input takes precedence. |
| `IBMCLOUD_COS_ACCESS_KEY_ID` | with `cos://` or `s3://` `backed-url` | HMAC access key for IBM Cloud Object Storage |
| `IBMCLOUD_COS_SECRET_ACCESS_KEY` | with `cos://` or `s3://` `backed-url` | HMAC secret key for IBM Cloud Object Storage |
| `IBMCLOUD_COS_ENDPOINT` | no | COS S3 endpoint (defaults to `s3.<region>.cloud-object-storage.appdomain.cloud`) |

## Inputs

| Name | Description | Required | Default |
|---|---|---|---|
| `operation` | `create` or `destroy` | No | `'create'` |
| `project-name` | mapt project name identifying the stack. Must match on destroy. | No | unique per job, stable within it |
| `region` | IBM Cloud region (e.g. `us-south`, `eu-de`) | Yes (or `IC_REGION`) | — |
| `zone` | IBM Cloud availability zone (e.g. `us-south-1`). Required for create. | Yes for create (or `IC_ZONE`) | — |
| `pull-secret` | OpenShift pull secret content | Yes for create (or `pull-secret-file`) | — |
| `pull-secret-file` | Path on the runner to a pull secret file | No | — |
| `version` | OpenShift version (e.g. `4.22.14`). Empty = latest in the catalog. | No | — |
| `vpc-id` | Reuse an existing VPC. Needs a mapt image newer than v0.14.7 (see `mapt-image`). | No | — |
| `cpus` | Minimum number of CPUs (integer ≥ 1) | No | `'8'` |
| `memory` | RAM in GiB (integer ≥ 1) | No | `'64'` |
| `gpus` | Number of GPUs (integer ≥ 0) | No | `'0'` |
| `gpu-manufacturer` | GPU manufacturer (e.g. `NVIDIA`) | No | — |
| `nested-virt` | Request nested virtualization (selects a bare metal server). Mutually exclusive with `spot`. | No | `'false'` |
| `compute-sizes` | Named IBM Cloud compute profiles (e.g. `bx2-16x64`); wins over cpus/memory/gpus | No | — |
| `compute-families` | Allowlist of compute family prefixes (e.g. `bx2,cx2`) | No | — |
| `disk-size` | Disk size in GB (integer ≥ 1). Ignored for bare metal servers. | No | `'200'` |
| `spot` | Request a spot virtual server instance | No | `'false'` |
| `profile` | Comma-separated profiles: `virtualization`, `serverless-serving`, `serverless-eventing`, `serverless`, `servicemesh`, `ai`, `nvidia` | No | — |
| `operator-channel` | Operator channel overrides, `package=channel` | No | — |
| `catalog-source` | Catalog source overrides, `package=index-image` | No | — |
| `disable-cluster-readiness` | Skip readiness checks (no kubeconfig is generated) | No | `'false'` |
| `tags` | Tags for the created resources (`name1=value1,name2=value2`) | No | — |
| `backed-url` | State backend: `file://` (default, job lifetime), `cos://bucket` or `s3://bucket` (both IBM COS). `azblob://` is not supported. | No | local, on the runner |
| `conn-details-output` | Directory (relative to the workspace) for connection details | No | `'snc-conn-details'` |
| `mapt-image` | Container image holding the mapt binary | No | `'quay.io/redhat-developer/mapt:v0.14.7'` |
| `debug` | Enable mapt debug traces (may expose partially masked credentials) | No | `'false'` |
| `force-destroy` | Destroy even when the stack state is locked (destroy only) | No | `'false'` |
| `keep-state` | Keep state files after a successful destroy (destroy only) | No | `'false'` |

## Outputs

| Name | Description |
|---|---|
| `host` | Floating IP of the instance (create only) |
| `username` | SSH username (`core`) (create only) |
| `id-rsa` | Path on the runner to the private key of the instance (create only) |
| `kubeconfig` | Path on the runner to the kubeconfig of the cluster (create only) |
| `conn-details` | Directory holding `host`, `username`, `id_rsa`, `kubeconfig` and `kubeadmin_pass` (create only) |
| `project-name` | Project name used for the stack; exported before provisioning starts. Pass it back on destroy. |

## Project name

The default project name is `snc-<run id>-<attempt>-<job suffix>`, derived from
`GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT` and `RUNNER_TRACKING_ID`. It is:

- **unique per job execution** — concurrent workflows, matrix legs and re-runs never collide;
- **stable across the steps of one job** — create and destroy compute the same default.

To destroy from a different job or workflow, pass `project-name` explicitly (it is always
available as an output of the create step).

## State management

mapt uses Pulumi state to know what to destroy. By default the state is kept on the runner
(`file:///workspace/.mapt` inside the mapt container), which works when the destroy runs in the
same job as the create — the common pattern shown above.

To destroy from a different job or workflow, use a remote backend and the same `project-name`.
Both `cos://bucket` and `s3://bucket` address an **IBM Cloud Object Storage** bucket (mapt maps
the `s3://` form onto COS with the regional endpoint):

```yaml
with:
  backed-url: cos://my-bucket
  project-name: my-stable-name
env:
  IBMCLOUD_API_KEY: ${{ secrets.IBMCLOUD_API_KEY }}
  IBMCLOUD_COS_ACCESS_KEY_ID: ${{ secrets.IBMCLOUD_COS_ACCESS_KEY_ID }}
  IBMCLOUD_COS_SECRET_ACCESS_KEY: ${{ secrets.IBMCLOUD_COS_SECRET_ACCESS_KEY }}
```

`azblob://` is not supported: the mapt ibmcloud provider only implements the COS backend.

## File ownership and permissions

The mapt container runs as root, so after a successful create the action:

- chowns the connection details and the local state directory to the runner user;
- sets mode `600` on `id_rsa`, `kubeconfig` and `kubeadmin_pass`;
- writes the pull secret to a unique temporary file under `RUNNER_TEMP` (mode `600`) that is
  removed when the step ends, whether it succeeded or failed.

Credentials are never written to logs. The `debug` input only enables mapt's own traces; mapt
masks credentials in them, but avoid it on public repositories anyway.

## Input validation

The action fails early, before any container runs, with actionable messages for: unknown
`operation`, boolean inputs that are not `true`/`false`, non-integer or below-minimum `cpus`,
`memory`, `gpus` and `disk-size`, `pull-secret` and `pull-secret-file` set together,
`nested-virt` with `spot`, unsupported `backed-url` schemes, COS backends without COS
credentials, malformed `operator-channel` / `catalog-source` items, and `vpc-id` with an image
that does not support it (pinned default `v0.14.7`).

## Bare metal servers and nested virtualization

IBM Cloud VPC supplies the KVM device on bare metal servers only. Set `nested-virt: 'true'` or
use the `virtualization` profile to request one; mapt then selects the smallest bare metal
profile matching `cpus`, `memory` and `compute-families`, or uses `compute-sizes` when given.
Before the create, mapt checks `ListBareMetalServerCapacities` and fails early when there is no
free capacity. A bare metal server costs more than a virtual server instance — check the
[IBM Cloud VPC pricing](https://www.ibm.com/products/virtual-servers/pricing) and always destroy
the cluster when it is no longer needed.

## Tests

Unit tests cover argument construction, input validation, project name consistency and cleanup
after provisioning failures. They run against a fake container runtime and need no cloud
credentials:

```bash
bash ibmcloud-snc/tests/run-tests.sh
```

They also run on every pull request (`.github/workflows/tests.yml`).

## Self-test

`.github/workflows/ibmcloud-snc-action.yml` runs this action against a real IBM Cloud account on
`workflow_dispatch`. It requires these repository secrets:

- `IBMCLOUD_API_KEY`
- `SNC_PULL_SECRET`
