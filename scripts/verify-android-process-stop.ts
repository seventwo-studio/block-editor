/** API26's am client can report 255 with an unknown stop outcome.
 * Confirm the package's actual terminal state; ambiguous readback
 * or a remaining process must never become a successful recovery campaign. */
export async function verifyAndroidProcessStop(
  command: (args: string[]) => Promise<string>, packageName: string,
): Promise<{ forceStopExit: 0 | 255; terminalConfirmed: true; processReadback?: "ps" }> {
  let forceStopExit: 0 | 255 = 0;
  let processReadback: "ps" | undefined;
  try { await command(["shell", "am", "force-stop", packageName]); }
  catch (error) {
    if ((error as { exitCode?: number }).exitCode !== 255) throw error;
    forceStopExit = 255;
  }
  let remaining: string;
  try { remaining = await command(["shell", "pidof", packageName]); }
  catch (error) {
    const result = error as { exitCode?: number; output?: string };
    if ((result.output ?? "").trim()) throw error;
    if (result.exitCode === 255) {
      // API26 can report 255 rather than pidof's ordinary no-match status.
      // Its empty response is ambiguous. Require a new successful process
      // listing with a recognized header and real rows before accepting it.
      const listing = await command(["shell", "ps", "-A"]);
      const lines = listing.trim().split(/\r?\n/), header = lines.shift()?.trim().split(/\s+/) ?? [];
      const pid = header.indexOf("PID"), name = header.indexOf("NAME");
      if (header[0] !== "USER" || pid !== 1 || header[2] !== "PPID" || name !== header.length - 1 || name <= pid || !lines.length ||
          header.filter(field => field === "PID").length !== 1 || header.filter(field => field === "NAME").length !== 1) {
        throw new Error("Ambiguous Android process-list header after unknown pidof outcome");
      }
      for (const line of lines) {
        const fields = line.trim().split(/\s+/);
        if (fields.length !== header.length || !/^[1-9]\d*$/.test(fields[pid]!)) {
          throw new Error("Ambiguous Android process-list row after unknown pidof outcome");
        }
        if (fields[name] === packageName || fields[name]!.startsWith(packageName + ":")) {
          throw new Error(`Android test package remains active after force-stop: ${packageName}`);
        }
      }
      processReadback = "ps";
    } else if (result.exitCode !== 1) throw error;
    remaining = "";
  }
  if (remaining.trim()) throw new Error(`Android test package remains active after force-stop: ${packageName}`);
  return { forceStopExit, terminalConfirmed: true, ...(processReadback ? { processReadback } : {}) };
}
