# Native writing release screening

The complete report measures all twelve shared writing workloads across explicitly selected protocols 4, 5 and 6 on clean source `4af7806c` / tree `3a681b85`. It uses one repetition with no excluded warmup. Native commands include JSON and process pipes; peak RSS covers the bridge child across all workloads. Rendering, parent-runner memory and assets are outside this boundary. Disk caches were uncontrolled.

The release bridge is 3,476,160 bytes. Fresh-process first-empty-session latency was 9.38 ms. Ordinary offline edit p95 ranged from 12.58 to 13.22 ms; at 2,048 edits per author it ranged from 74.67 to 84.64 ms. Large-history rejoin p95 ranged from 1.68 to 1.72 seconds, and restore from 2.78 to 2.88 seconds. Peak child RSS was 323,059,712 bytes. These are screening observations; numerical release limits remain unagreed. ST-94/ST-39 require the full repeated, source-qualified runtime matrix and agreed limits.

The separate incomplete report retains its original `c396e8fb` / `dd707b7b` identities. It collected all twelve samples, but `/usr/bin/time -l` could not access `kern.clockrate` under the sandbox; the wrapper exited 1 and peak memory was unavailable. Its `complete: false`, error and original resource log remain intact. It is excluded from acceptance.

File hashes and exact artifact/source identities are recorded in `manifest.json`. Earlier reports retain their original paths and identities. This evidence does not establish installed native input, minimum-device performance or seven-runtime release acceptance.
