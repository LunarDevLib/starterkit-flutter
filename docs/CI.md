# CI routing and full verification

`Flutter / verify` is the stable aggregate check. Every run always executes the
common locked Flutter/Dart checks and the independent Swift policy tests. Native
baseline and QR consumer jobs are selected conservatively from the changed paths;
the planner is loaded from the trusted PR base, push-before, or default-branch
revision, never from the candidate PR. If that trusted planner is unavailable or
cannot classify the event, the router selects the full matrix.

The plan job gates the common checks, Swift policy tests, Android baseline,
renamed-copy, baseline iOS, and QR iOS jobs, which then run independently in
parallel when selected. The final aggregate waits for their results: Swift/native
failure or timeout still fails the selected plan; parallelism does not waive a
gate. Job timeouts bound hangs (15 minutes for common/Swift, 25 for Android and
QR iOS, 30 for baseline iOS; 5 for planner/aggregate).

The normal triggers remain all pull requests, pushes to `main`, and manual
dispatch. A manual run defaults to impact routing. To run the full baseline/native
freeze matrix, dispatch from the final branch and force `full`:

```sh
gh workflow run flutter.yml -f full=true --ref <final-branch>
```

Confirm the dispatched run's head SHA is the intended final CI revision before
using it as freeze evidence. The full plan includes source/renamed Android and
iOS baseline builds and selected QR opt-in consumer coverage. A skipped job is
not fresh build evidence; the aggregate fails if a job selected by the plan is
missing, skipped, cancelled, or unsuccessful. Unselected native jobs do not
claim a new artifact or runtime verification.

Pure Dart capability-package changes can use common validation without unrelated
native builds. Native package changes route to the affected platform; root app,
platform configuration, shared verifier/fixture, dependency, bootstrap, CI, or
uncertain changes expand toward the full matrix. The routing decision and reason
are available in the plan job output. No runtime estimate or measured speedup is
asserted; actual latency depends on GitHub runner availability and dependency-cache
state.

The full CI matrix does not prove signed release readiness, physical-device
behavior, production service behavior, or branch-protection configuration.
