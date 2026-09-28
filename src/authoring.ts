import {
  type SimpleBlockType,
  filterSlashCommands,
  getBlockText,
  makeBlock,
  toSimpleType,
} from "./model.js";
import type { Block } from "./schema.js";

export type AuthoringBlockType = SimpleBlockType | "image";
/** Paragraphs remain available as the empty-document and plain-text fallback. */
export function allowsBlockType(
  type: AuthoringBlockType,
  allowed?: readonly AuthoringBlockType[],
): boolean {
  return !allowed || type === "paragraph" || allowed.includes(type);
}
export function allowsAuthoredBlock(
  block: Block,
  allowed?: readonly AuthoringBlockType[],
): boolean {
  if (!allowed) return true;
  if (block.type === "image") return allowsBlockType("image", allowed);
  if (["embed", "math", "toggle"].includes(block.type)) return false;
  return allowsBlockType(toSimpleType(block), allowed);
}
export function authoringCommands(
  query: string | null,
  allowed?: readonly AuthoringBlockType[],
) {
  return filterSlashCommands(query).filter((command) =>
    allowsBlockType(command.id, allowed),
  );
}
/** Only normalize newly imported content; never rewrite an existing host document. */
export function constrainImportedBlocks(
  blocks: Block[],
  allowed?: readonly AuthoringBlockType[],
): Block[] {
  return blocks.map((block) =>
    allowsAuthoredBlock(block, allowed)
      ? block
      : { ...makeBlock("paragraph", getBlockText(block)), id: block.id },
  );
}
