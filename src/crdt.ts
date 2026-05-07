import type { Block } from "./schema.js"

export interface CrdtClock {
  readonly counter: number
  readonly siteId: string
}

export interface BlockEditorCrdtState {
  readonly siteId: string
  readonly clock: number
  readonly blocks: readonly Block[]
  readonly operations: readonly BlockEditorOperation[]
}

export type BlockEditorOperation =
  | {
      readonly type: "insert"
      readonly id: string
      readonly block: Block
      readonly index: number
      readonly clock: CrdtClock
    }
  | {
      readonly type: "update"
      readonly id: string
      readonly block: Block
      readonly clock: CrdtClock
    }
  | {
      readonly type: "move"
      readonly id: string
      readonly index: number
      readonly clock: CrdtClock
    }
  | {
      readonly type: "delete"
      readonly id: string
      readonly clock: CrdtClock
    }

type BlockRecord = {
  block: Block
  index: number
  deleted: boolean
  updatedAt: CrdtClock
  movedAt: CrdtClock
  deletedAt?: CrdtClock
}

export function createCrdtState(
  siteId: string,
  blocks: readonly Block[] = [],
): BlockEditorCrdtState {
  return {
    siteId,
    clock: 0,
    blocks: [...blocks],
    operations: blocks.map((block, index) => ({
      type: "insert",
      id: block.id,
      block,
      index,
      clock: { counter: 0, siteId },
    })),
  }
}

export function nextClock(state: BlockEditorCrdtState): CrdtClock {
  return { counter: state.clock + 1, siteId: state.siteId }
}

export function insertBlockOperation(
  state: BlockEditorCrdtState,
  block: Block,
  index = state.blocks.length,
): BlockEditorOperation {
  return {
    type: "insert",
    id: block.id,
    block,
    index,
    clock: nextClock(state),
  }
}

export function updateBlockOperation(
  state: BlockEditorCrdtState,
  block: Block,
): BlockEditorOperation {
  return {
    type: "update",
    id: block.id,
    block,
    clock: nextClock(state),
  }
}

export function moveBlockOperation(
  state: BlockEditorCrdtState,
  id: string,
  index: number,
): BlockEditorOperation {
  return {
    type: "move",
    id,
    index,
    clock: nextClock(state),
  }
}

export function deleteBlockOperation(
  state: BlockEditorCrdtState,
  id: string,
): BlockEditorOperation {
  return {
    type: "delete",
    id,
    clock: nextClock(state),
  }
}

export function applyOperation(
  state: BlockEditorCrdtState,
  operation: BlockEditorOperation,
): BlockEditorCrdtState {
  const operations = dedupeOperations([...state.operations, operation])
  return materializeState(state.siteId, operations)
}

export function mergeCrdtStates(
  local: BlockEditorCrdtState,
  remote: BlockEditorCrdtState,
): BlockEditorCrdtState {
  return materializeState(
    local.siteId,
    dedupeOperations([...local.operations, ...remote.operations]),
  )
}

export function encodeCrdtState(state: BlockEditorCrdtState): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(state.operations))
}

export function decodeCrdtState(
  siteId: string,
  payload: Uint8Array,
): BlockEditorCrdtState {
  const operations = JSON.parse(new TextDecoder().decode(payload))
  if (!Array.isArray(operations)) {
    throw new Error("Invalid block editor CRDT payload")
  }
  return materializeState(siteId, operations as BlockEditorOperation[])
}

function materializeState(
  siteId: string,
  operations: readonly BlockEditorOperation[],
): BlockEditorCrdtState {
  const records = new Map<string, BlockRecord>()
  let clock = 0

  for (const operation of operations) {
    clock = Math.max(clock, operation.clock.counter)
    const existing = records.get(operation.id)

    if (operation.type === "insert") {
      if (!existing || compareClock(operation.clock, existing.updatedAt) > 0) {
        records.set(operation.id, {
          block: operation.block,
          index: operation.index,
          deleted: existing?.deleted ?? false,
          updatedAt: operation.clock,
          movedAt: existing?.movedAt ?? operation.clock,
          deletedAt: existing?.deletedAt,
        })
      }
      continue
    }

    if (!existing) continue

    if (operation.type === "update") {
      if (compareClock(operation.clock, existing.updatedAt) >= 0) {
        existing.block = operation.block
        existing.updatedAt = operation.clock
      }
      continue
    }

    if (operation.type === "move") {
      if (compareClock(operation.clock, existing.movedAt) >= 0) {
        existing.index = operation.index
        existing.movedAt = operation.clock
      }
      continue
    }

    if (
      operation.type === "delete" &&
      (!existing.deletedAt ||
        compareClock(operation.clock, existing.deletedAt) >= 0)
    ) {
      existing.deleted = true
      existing.deletedAt = operation.clock
    }
  }

  const blocks = Array.from(records.values())
    .filter((record) => !record.deleted)
    .sort((a, b) => {
      if (a.index !== b.index) return a.index - b.index
      return compareClock(a.movedAt, b.movedAt)
    })
    .map((record) => record.block)

  return {
    siteId,
    clock,
    blocks,
    operations: dedupeOperations(operations),
  }
}

function dedupeOperations(
  operations: readonly BlockEditorOperation[],
): BlockEditorOperation[] {
  const byKey = new Map<string, BlockEditorOperation>()
  for (const operation of operations) {
    byKey.set(operationKey(operation), operation)
  }
  return Array.from(byKey.values()).sort((a, b) =>
    compareClock(a.clock, b.clock),
  )
}

function operationKey(operation: BlockEditorOperation): string {
  return `${operation.clock.siteId}:${operation.clock.counter}:${operation.type}:${operation.id}`
}

function compareClock(a: CrdtClock, b: CrdtClock): number {
  if (a.counter !== b.counter) return a.counter - b.counter
  return a.siteId.localeCompare(b.siteId)
}
