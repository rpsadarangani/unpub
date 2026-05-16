<!--
Thanks for opening a PR. Please fill in the sections below.
-->

## Summary

<!-- 1-3 bullets describing what changed and why. -->

## Test plan

<!--
A checklist of what you verified locally. At a minimum:

- [ ] `dart analyze` clean on `unpub_aws/lib`
- [ ] If you touched the chart: `helm lint charts/unpub` + `helm template ut charts/unpub --set istio.enabled=true --set serviceMonitor.enabled=true`
- [ ] If you touched server logic: ran the binary against `docker-compose.dev.yml` and verified the affected endpoint (publish / fetch / install / `/metrics`)
-->

## Notes for the reviewer

<!--
Anything that needs extra attention — risk areas, backward-incompat changes, follow-up work, etc.
-->
