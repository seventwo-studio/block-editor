// One fixture contract for native Swift and actual browser WASM execution.
// Android emits the same raw-response transcript through packaged JNI.
export const fixtureNames = ['bridge', 'structure', 'recovery', 'documents', 'writing', 'blockCommands', 'schemaCommands', 'roleCommands', 'collectionCommands', 'exitCommands', 'pinCommands', 'boundaryCommands'];

export function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}

function equal(actual, expected, label) {
  if (JSON.stringify(canonical(actual)) !== JSON.stringify(canonical(expected))) {
    throw new Error(`${label}: actual ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}`);
  }
}

export async function runFixture(name, fixture, call) {
  const responses = [], captured = {};
  const request = async (input, expectedError) => {
    const response = await call(input);
    responses.push(response);
    equal(response.ok, !expectedError, `${name} response ${responses.length - 1} status`);
    if (expectedError) equal(response.error, expectedError, `${name} error ${responses.length - 1}`);
    return response;
  };
  if (name === 'documents') {
    for (const [index, sample] of fixture.valid.entries()) {
      const session = `corpus-${index}`, restored = `${session}-restored`;
      await request({ command: 'create', session, documentID: sample.name, actorID: 'local', blocks: sample.blocks });
      const saved = await request({ command: 'save', session });
      const opened = await request({ command: 'restore', session: restored, actorID: 'local', snapshot: saved.value });
      equal(opened.value.blocks, sample.blocks, `${name} ${sample.name}`);
      await request({ command: 'close', session });
      await request({ command: 'close', session: restored });
    }
    for (const [index, sample] of fixture.invalid.entries()) {
      const response = await call({ command: 'create', session: `invalid-${index}`, documentID: sample.name, actorID: 'local', blocks: sample.blocks });
      responses.push(response);
      equal(response.ok, false, `${name} invalid ${sample.name}`);
      if (typeof response.error !== 'string' || !response.error) throw new Error(`${name}: missing explicit document error`);
    }
  } else if (name === 'bridge') {
    for (const input of fixture.requests) await request(input);
    equal(responses.at(-1).value, fixture.expected, `${name} final document`);
  } else {
    for (const step of fixture.steps) {
      const input = structuredClone(step.request);
      for (const [key, binding] of Object.entries(step.bindings ?? {})) {
        const path = Array.isArray(binding) ? binding : [binding];
        input[key] = path.reduce((value, part) => value[part], captured);
        if (input[key] === undefined) throw new Error(`${name}: missing binding ${path.join('.')}`);
      }
      const response = await request(input, step.error);
      if (step.capture) {
        captured[step.capture] = step.error ? response.recovery : response.value;
        if (captured[step.capture] === undefined) throw new Error(`${name}: missing capture ${step.capture}`);
      }
    }
    for (const [left, right] of fixture.equal ?? []) {
      if (captured[left] === undefined || captured[right] === undefined) throw new Error(`${name}: missing comparison capture ${left}/${right}`);
      equal(captured[left], captured[right], `${name} ${left}/${right}`);
    }
    for (const [capture, blocks] of Object.entries(fixture.expectedBlocks ?? {})) {
      if (captured[capture]?.blocks === undefined) throw new Error(`${name}: missing document capture ${capture}`);
      equal(captured[capture].blocks, blocks, `${name} ${capture} preserved document`);
    }
    if (name === 'structure') {
      equal(captured.final, fixture.expected, `${name} final document`);
      equal(captured.resolvedPosition, fixture.expectedPosition, `${name} selection`);
      equal(captured.cutover, fixture.expectedCutover, `${name} migration`);
      equal(captured.cutoverChanges.version, 2, `${name} protocol`);
    } else if (name === 'recovery') {
      equal(captured.cleared, null, `${name} cleared recovery`);
      equal(captured.proposalA.reason, 'identityConflict', `${name} recovery reason`);
      equal(captured.proposalA.batch.changes.length, 2, `${name} retained histories`);
      equal(captured.finalA, fixture.expected, `${name} final document`);
      equal(captured.afterUndo, fixture.expectedAfterUndo, `${name} author undo`);
    }
    for (const [capture, expected] of Object.entries(fixture.expectedValues ?? {})) {
      equal(captured[capture], expected, `${name} ${capture}`);
    }
  }
  return canonical({ responses });
}
