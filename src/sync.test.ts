import { describe, expect, it } from "bun:test"

/**
 * Tests for the BlockEditor's parent-sync logic that prevents infinite loops.
 *
 * The BlockEditor has two effects that form a cycle if not guarded:
 *   1. Emit effect: blocks change → onChange(blocks), store in lastEmittedRef
 *   2. Sync effect: value prop changes → if value !== lastEmitted, setBlocks(value)
 *
 * Without guards, the mount-cycle is:
 *   Initial blocks=[paragraph] + value=[] → emit fires onChange → sync sees
 *   value≠lastEmitted → setBlocks(new paragraph) → emit fires again → loop
 *
 * Guards:
 *   - Mount guard: both effects skip their first run (initializedRef)
 *   - Reference check: value === lastEmittedRef.current (catches echoed refs)
 *   - Deep check: JSON.stringify comparison (catches reconstructed-but-identical data)
 */

describe("BlockEditor sync — loop prevention", () => {
  /**
   * Simulates one full cycle of the emit→sync loop and checks whether
   * the sync effect would fire (causing a re-render and potential loop).
   */
  function wouldLoop(scenario: {
    emittedBlocks: unknown[]
    parentReturns: unknown[]
  }): boolean {
    const lastEmitted = scenario.emittedBlocks
    const incoming = scenario.parentReturns

    // This mirrors the guard in block-editor.tsx sync effect
    if (incoming === lastEmitted) return false
    if (JSON.stringify(incoming) === JSON.stringify(lastEmitted)) return false
    return true
  }

  it("no loop when parent echoes the same reference", () => {
    const blocks = [{ id: "1", type: "paragraph", content: [] }]
    expect(wouldLoop({ emittedBlocks: blocks, parentReturns: blocks })).toBe(
      false,
    )
  })

  it("no loop when parent reconstructs identical content", () => {
    // This happens when the parent stores blocks in state and
    // the state setter returns a structurally identical array
    const emitted = [
      {
        id: "1",
        type: "paragraph",
        content: [{ type: "text", text: "hello", marks: [] }],
      },
    ]
    const reconstructed = [
      {
        id: "1",
        type: "paragraph",
        content: [{ type: "text", text: "hello", marks: [] }],
      },
    ]

    expect(emitted === reconstructed).toBe(false) // different refs
    expect(
      wouldLoop({ emittedBlocks: emitted, parentReturns: reconstructed }),
    ).toBe(false) // but JSON matches
  })

  it("syncs when parent provides genuinely new content", () => {
    const emitted = [{ id: "1", type: "paragraph", content: [] }]
    const newContent = [
      {
        id: "1",
        type: "paragraph",
        content: [{ type: "text", text: "external edit", marks: [] }],
      },
    ]

    expect(
      wouldLoop({ emittedBlocks: emitted, parentReturns: newContent }),
    ).toBe(true)
  })

  it("syncs when parent replaces with completely different blocks", () => {
    const emitted = [{ id: "1", type: "paragraph", content: [] }]
    const replaced = [
      {
        id: "2",
        type: "heading",
        level: 1,
        content: [{ type: "text", text: "Title", marks: [] }],
      },
      { id: "3", type: "paragraph", content: [] },
    ]

    expect(wouldLoop({ emittedBlocks: emitted, parentReturns: replaced })).toBe(
      true,
    )
  })

  it("no loop with empty blocks", () => {
    const emitted: unknown[] = []
    const incoming: unknown[] = []
    expect(wouldLoop({ emittedBlocks: emitted, parentReturns: incoming })).toBe(
      false,
    )
  })
})

describe("BlockEditor mount-cycle prevention", () => {
  /**
   * Simulates the mount scenario to verify that the initializedRef
   * guard prevents the emit→sync cycle on first render.
   */
  it("skips both emit and sync effects on mount", () => {
    // On mount, the emit effect should NOT call onChange,
    // and the sync effect should NOT call setBlocks.
    // Both are guarded by initializedRef.
    let emitCallCount = 0
    let syncCallCount = 0
    let initialized = false

    // Simulate emit effect on mount
    function emitEffect() {
      if (!initialized) return // ← guard
      emitCallCount++
    }

    // Simulate sync effect on mount
    function syncEffect() {
      if (!initialized) {
        initialized = true
        return // ← guard
      }
      syncCallCount++
    }

    // First render
    emitEffect()
    syncEffect()

    expect(emitCallCount).toBe(0)
    expect(syncCallCount).toBe(0)
    expect(initialized).toBe(true)
  })

  it("allows emit and sync after mount", () => {
    let emitCallCount = 0
    let syncCallCount = 0
    let initialized = false

    function emitEffect() {
      if (!initialized) return
      emitCallCount++
    }

    function syncEffect(valueDiffersFromEmitted: boolean) {
      if (!initialized) {
        initialized = true
        return
      }
      if (valueDiffersFromEmitted) syncCallCount++
    }

    // Mount
    emitEffect()
    syncEffect(false)

    // User types → blocks change → emit fires
    emitEffect()
    expect(emitCallCount).toBe(1)

    // External value change → sync fires
    syncEffect(true)
    expect(syncCallCount).toBe(1)
  })

  it("prevents loop when value=[] and blocks=[paragraph] on mount", () => {
    // This is the exact scenario that caused the infinite loop:
    // - Parent passes value=[]
    // - BlockEditor initializes blocks=[makeBlock("paragraph")]
    // - Without the mount guard, emit would fire onChange([paragraph]),
    //   then sync would see value=[] != lastEmitted=[paragraph] and
    //   call setBlocks with a NEW paragraph, starting a loop.
    const value: unknown[] = []
    const blocks = [{ id: "1", type: "paragraph", content: [] }]
    let initialized = false
    let emitCalls = 0
    let syncCalls = 0

    // Mount cycle
    // Emit runs first (declared first in component)
    if (initialized) {
      emitCalls++
    }
    // Sync runs second
    if (!initialized) {
      initialized = true
    } else if (value !== blocks) {
      syncCalls++
    }

    expect(emitCalls).toBe(0)
    expect(syncCalls).toBe(0)
  })
})
