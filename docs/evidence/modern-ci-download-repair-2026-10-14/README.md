# Fail-closed CI download repair

Run 38583783872 / head cc0950f1 failed API26 job 115920243270 on the pinned NDK hash before editor compilation. The installer deleted rejected bytes and recorded no actual digest/size/headers; the precise cause is unproven. Both API35 installers passed the same pin. Original raw/sanitized job logs and the still-running run snapshot remain retained; other partial successes are not an all-job pass.

Source 74de1ac retains strict original SHA-256 and declared size, rejection metadata/files, and bounded fresh-cache repair only for identified partial/truncated/transient transfers. Complete wrong-hash payloads, denied access and certificate errors halt. Existing hash-only entries keep mandatory digest checks. Diagnostic receipts upload even before installation completes. No pins or protection/credential/billing boundaries changed.

Seven real local HTTP cases pass, including exact bytes, short/partial repair, wrong hash, denial, exhaustion and hash-only locks; eight provenance regressions pass. A separate official NDK probe returns HTTP200, all 738633529 bytes and the exact locked SHA-256 on its first attempt. This does not retroactively pass the failure or prove its unrecorded cause. The verified SDK archive stays local; only metadata is committed. Fresh CI still needs all seven current required jobs.

[Receipt](receipt.json) and [hashes](hashes.json) retain exact identities and qualifications. Remaining finishing/performance/native publication/physical/final acceptance gates remain open.
