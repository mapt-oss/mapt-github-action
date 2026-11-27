# MAPT GitHub Actions

A collection of GitHub Actions for provisioning and managing infrastructure using [MAPT](https://github.com/redhat-developer/mapt).

## Available Actions

| Action | Description |
|---|---|
| [ibmcloud-snc](./ibmcloud-snc) | Create and destroy single-node OpenShift clusters on IBM Cloud VPC. |

Each action provides its own documentation, including prerequisites, usage examples, inputs, and outputs.

## Development

Each action keeps its Bash implementation in a `run.sh` script next to its `action.yml`, with unit tests under `tests/` that run against a fake container runtime (no cloud credentials needed):

```bash
bash ibmcloud-snc/tests/run-tests.sh
```

The tests run on every pull request. Workflows that exercise the actions against real cloud providers run on `workflow_dispatch` only, since they create billable resources.