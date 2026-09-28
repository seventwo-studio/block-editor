import { useState } from "react";
import { createRoot } from "react-dom/client";
import { BlockEditor } from "../../src/react";
import type { Block } from "../../src/schema";
import "../../src/react.css";

// Development-only fixture: not a Vite build entry or storage implementation.
function Fixture() {
  const [blocks, setBlocks] = useState<Block[]>([
    {
      id: "start",
      type: "paragraph",
      content: [{ type: "text", text: "First", marks: [] }],
    },
  ]);
  const [documentKey, setDocumentKey] = useState("first");
  const [resolve, setResolve] = useState(true);
  const [aborted, setAborted] = useState(0);
  return (
    <main style={{ maxWidth: 600, margin: "auto" }}>
      <button
        type="button"
        onClick={() =>
          setBlocks([
            {
              id: "new-document",
              type: "paragraph",
              content: [{ type: "text", text: "Other document", marks: [] }],
            },
          ])
        }
      >
        Switch document
      </button>
      <button type="button" onClick={() => setDocumentKey("another")}>
        Switch identical document
      </button>
      <label>
        <input
          type="checkbox"
          checked={resolve}
          onChange={(event) => setResolve(event.target.checked)}
        />
        Resolve previews
      </label>
      <button
        type="button"
        onClick={() =>
          setBlocks([
            {
              id: "stored",
              type: "image",
              src: "https://untrusted.invalid/image.png",
              alt: "Stored asset",
              caption: [],
            },
          ])
        }
      >
        Load stored image
      </button>
      <BlockEditor
        documentKey={documentKey}
        value={blocks}
        onChange={setBlocks}
        allowMarkdown={false}
        imageUpload={{
          mimeTypes: ["image/png", "image/jpeg", "image/webp"],
          maxBytes: 1024,
          upload: async (file, { signal }) => {
            signal.addEventListener(
              "abort",
              () => setAborted((value) => value + 1),
              { once: true },
            );
            const response = await fetch("/test-upload", {
              method: "POST",
              body: file,
              signal,
            });
            if (!response.ok) throw new Error("Upload rejected");
            return response.json();
          },
        }}
        resolveImageSource={
          resolve
            ? (source) => `/test-image/${encodeURIComponent(source)}`
            : undefined
        }
      />
      <pre id="document">{JSON.stringify(blocks)}</pre>
      <output aria-label="Aborted uploads">{aborted}</output>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);
