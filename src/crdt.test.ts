import { describe, expect, it } from "bun:test"
import {
  applyOperation,
  createCrdtState,
  decodeCrdtState,
  deleteBlockOperation,
  encodeCrdtState,
  insertBlockOperation,
  makeBlock,
  mergeCrdtStates,
  moveBlockOperation,
  updateBlockOperation,
} from "."

describe("block editor CRDT state", () => {
  it("applies inserts, updates, moves, and deletes through operations", () => {
    let state = createCrdtState("a")
    const first = makeBlock("paragraph", "First")
    const second = makeBlock("paragraph", "Second")

    state = applyOperation(state, insertBlockOperation(state, first))
    state = applyOperation(state, insertBlockOperation(state, second))
    state = applyOperation(
      state,
      updateBlockOperation(state, {
        ...first,
        content: [{ type: "text", text: "Updated", marks: [] }],
      }),
    )
    state = applyOperation(state, moveBlockOperation(state, second.id, 0))
    state = applyOperation(state, deleteBlockOperation(state, first.id))

    expect(state.blocks.map((block) => block.id)).toEqual([second.id])
  })

  it("merges concurrent replicas deterministically", () => {
    const base = createCrdtState("a", [makeBlock("paragraph", "Base")])
    const localBlock = makeBlock("paragraph", "Local")
    const remoteBlock = makeBlock("paragraph", "Remote")
    const local = applyOperation(
      base,
      insertBlockOperation(base, localBlock, 1),
    )
    const remote = applyOperation(
      { ...base, siteId: "b" },
      insertBlockOperation({ ...base, siteId: "b" }, remoteBlock, 1),
    )

    const mergedLocal = mergeCrdtStates(local, remote)
    const mergedRemote = mergeCrdtStates(remote, local)

    expect(mergedLocal.blocks.map((block) => block.id)).toEqual(
      mergedRemote.blocks.map((block) => block.id),
    )
    expect(mergedLocal.blocks).toHaveLength(3)
  })

  it("round-trips operation payloads", () => {
    let state = createCrdtState("a")
    state = applyOperation(
      state,
      insertBlockOperation(state, makeBlock("heading1", "Title")),
    )

    const decoded = decodeCrdtState("b", encodeCrdtState(state))
    expect(decoded.blocks).toEqual(state.blocks)
    expect(decoded.operations).toEqual(state.operations)
  })
})
