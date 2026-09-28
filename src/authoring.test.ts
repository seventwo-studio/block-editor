import { describe, expect, it } from "bun:test";
import {
  allowsBlockType,
  authoringCommands,
  constrainImportedBlocks,
} from "./authoring.js";
import { makeBlock } from "./model.js";

describe("host authoring block controls", () => {
  it("preserves the default command set and a paragraph fallback for empty restrictions", () => {
    expect(
      authoringCommands("").some((command) => command.id === "table"),
    ).toBe(true);
    expect(authoringCommands("", []).map((command) => command.id)).toEqual([
      "paragraph",
    ]);
    expect(allowsBlockType("image", [])).toBe(false);
    expect(allowsBlockType("paragraph", [])).toBe(true);
  });
  it("normalizes only newly imported unsupported blocks without losing their text or identity", () => {
    const heading = makeBlock("heading2", "Title");
    const code = makeBlock("code", "let x = 1");
    const result = constrainImportedBlocks([heading, code], ["heading2"]);
    expect(result[0]).toBe(heading);
    expect(result[1]).toMatchObject({
      id: code.id,
      type: "paragraph",
      content: [{ type: "text", text: "let x = 1", marks: [] }],
    });
    expect(code.type).toBe("code");
    expect(constrainImportedBlocks([code])[0]).toBe(code);
  });
});
