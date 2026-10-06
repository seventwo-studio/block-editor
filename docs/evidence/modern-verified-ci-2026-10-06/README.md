# Retained Verified-candidate Swift deadline failure

Source: `0ca14f7cfa58a3677035afb62f4e48ebbaf75922`, tree
`92971cee5123b3afdb616a35bc915af32bf30320`, PR #70.
[CI run 37436693154](https://github.com/seventwo-studio/block-editor/actions/runs/37436693154),
Swift job `112180135638`, started 08:31:46 UTC and completed cancelled at
09:16:58 UTC on 6 October 2026. The job's configured deadline was 45 minutes.

The complete original log and job/step receipt are retained here; `files.json`
pins their SHA-256 hashes. This is failed job evidence, not a passed required
Swift check. The log records 573 shared-core tests, 89 Apple-host tests and eight
transport tests passing, followed by shared ABI/adapter/compatibility fixtures.
The release build completed at 09:16:47 UTC, then the optimized measurement
step was cancelled at 09:16:51 UTC. Native provenance was skipped. The full
job therefore did not finish, despite its completed tests and builds.

The previous successful Swift job in run 37401934453 took 44.9 minutes. The
repair gives the existing Swift job 75 minutes without removing its checks or
changing editor behavior. CI concurrency now separates distinct source commits
so an expensive older candidate can finish and retain evidence; duplicate runs
of the same candidate still cancel. This does not make older results current
or permit delivery before the new candidate's required checks succeed.

At diagnosis, test, WASM and both x86 Android jobs had passed for the failed
candidate; ARM Android was still running. Follow the live run for its eventual
outcome. Do not label an unfinished or cancelled job as passed.
