/** A completed instrumentation process can disappear while API26's am client
 * reports 255. Confirm the package's actual terminal state; ambiguous readback
 * or a remaining process must never become a successful recovery campaign. */
export async function verifyAndroidProcessStop(
  command: (args: string[]) => Promise<string>, packageName: string,
): Promise<{ forceStopExit: 0 | 255; terminalConfirmed: true }> {
  let forceStopExit: 0 | 255 = 0;
  try { await command(["shell", "am", "force-stop", packageName]); }
  catch (error) {
    if ((error as { exitCode?: number }).exitCode !== 255) throw error;
    forceStopExit = 255;
  }
  let remaining: string;
  try { remaining = await command(["shell", "pidof", packageName]); }
  catch (error) {
    const result = error as { exitCode?: number; output?: string };
    if (result.exitCode !== 1 || (result.output ?? "").trim()) throw error;
    remaining = "";
  }
  if (remaining.trim()) throw new Error(`Android test package remains active after force-stop: ${packageName}`);
  return { forceStopExit, terminalConfirmed: true };
}
