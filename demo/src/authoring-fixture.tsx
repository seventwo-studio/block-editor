import { useState } from "react";
import { createRoot } from "react-dom/client";
import { BlockEditor } from "../../src/react";
import {
  makeBlock,
  type Block,
  type AuthoringBlockType,
} from "../../src/index";
import "../../src/react.css";
const allowed: readonly AuthoringBlockType[] = [
  "heading1",
  "heading2",
  "heading3",
  "bullet",
  "ordered",
  "quote",
  "code",
  "divider",
];
function Fixture() {
  const [blocks, setBlocks] = useState<Block[]>([makeBlock("paragraph")]);
  const [restricted, setRestricted] = useState(true);
  const [paragraphsOnly, setParagraphsOnly] = useState(false);
  return (
    <main>
      <button onClick={() => setParagraphsOnly(true)}>Paragraphs only</button>
      <button onClick={() => setRestricted(!restricted)}>
        Toggle restrictions
      </button>
      <button onClick={() => setBlocks([makeBlock("todo", "Saved task")])}>
        Load existing task
      </button>
      <BlockEditor
        value={blocks}
        onChange={setBlocks}
        allowedBlockTypes={
          paragraphsOnly ? [] : restricted ? allowed : undefined
        }
        imageUpload={{
          mimeTypes: ["image/png"],
          maxBytes: 1000,
          upload: async () => ({ src: "test-asset" }),
        }}
      />
      <pre data-testid="document">{JSON.stringify(blocks)}</pre>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);
