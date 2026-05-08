import {
  type Block,
  type BlockEditorCrdtState,
  applyOperation,
  createCrdtState,
  deleteBlockOperation,
  insertBlockOperation,
  makeBlock,
  moveBlockOperation,
  serializeBlocksToMarkdown,
  updateBlockOperation,
} from "@seventwo-studio/block-editor"
import {
  type BlockEditorUiOperation,
  BlockEditor,
} from "@seventwo-studio/block-editor/react"
import "@seventwo-studio/block-editor/react.css"
import { useMemo, useState } from "react"

const seedBlocks: Block[] = [
  makeBlock("heading1", "Portable block documents"),
  makeBlock(
    "paragraph",
    "This browser-only React surface ships with the package and emits structured block operations.",
  ),
  makeBlock("todo", "Tune the theme without touching editor logic"),
  makeBlock("callout", "Use CSS variables to make the editor feel native."),
  makeBlock("code", "const blocks = editor.getDocument()"),
]

const themes = {
  meadow: {
    name: "Meadow",
    bg: "#fbfaf5",
    panel: "#ffffff",
    surface: "#f1efe5",
    strong: "#e3dfcf",
    text: "#1f211d",
    muted: "#767165",
    border: "#ded8c5",
    accent: "#355c4a",
    radius: 12,
    font: "Inter, ui-sans-serif, system-ui, sans-serif",
  },
  midnight: {
    name: "Midnight",
    bg: "#101216",
    panel: "#171a20",
    surface: "#20242d",
    strong: "#2b313b",
    text: "#f2f4f7",
    muted: "#aab0bd",
    border: "#303743",
    accent: "#9ccfd8",
    radius: 8,
    font: "Inter, ui-sans-serif, system-ui, sans-serif",
  },
  editorial: {
    name: "Editorial",
    bg: "#f7f4ef",
    panel: "#fffdf8",
    surface: "#eee7da",
    strong: "#ded2be",
    text: "#251d16",
    muted: "#796c5d",
    border: "#ddd0bd",
    accent: "#9d4f32",
    radius: 3,
    font: "Georgia, Cambria, serif",
  },
} as const

type ThemeKey = keyof typeof themes
type LoggedOperation = {
  id: string
  operation: BlockEditorUiOperation
}

export default function App() {
  const [themeKey, setThemeKey] = useState<ThemeKey>("meadow")
  const [accent, setAccent] = useState<string>(themes.meadow.accent)
  const [radius, setRadius] = useState<number>(themes.meadow.radius)
  const [blocks, setBlocks] = useState(seedBlocks)
  const [crdt, setCrdt] = useState<BlockEditorCrdtState>(() =>
    createCrdtState("demo", seedBlocks),
  )
  const [operations, setOperations] = useState<LoggedOperation[]>([])

  const theme = themes[themeKey]
  const editorStyle = {
    "--s2be-bg": theme.panel,
    "--s2be-surface": theme.surface,
    "--s2be-surface-strong": theme.strong,
    "--s2be-text": theme.text,
    "--s2be-muted": theme.muted,
    "--s2be-border": theme.border,
    "--s2be-accent": accent,
    "--s2be-radius": `${radius}px`,
    "--s2be-font": theme.font,
  } as React.CSSProperties

  const markdown = useMemo(() => serializeBlocksToMarkdown(blocks), [blocks])

  function handleOperation(operation: BlockEditorUiOperation, next: Block[]) {
    setOperations((current) =>
      [
        {
          id: crypto.randomUUID(),
          operation,
        },
        ...current,
      ].slice(0, 12),
    )
    setCrdt((current) => applyUiOperation(current, operation, next))
  }

  function selectTheme(next: ThemeKey) {
    setThemeKey(next)
    setAccent(themes[next].accent)
    setRadius(themes[next].radius)
  }

  return (
    <main
      className="demo-shell"
      style={{
        "--demo-bg": theme.bg,
        "--demo-panel": theme.panel,
        "--demo-surface": theme.surface,
        "--demo-text": theme.text,
        "--demo-muted": theme.muted,
        "--demo-border": theme.border,
        "--demo-accent": accent,
        "--demo-radius": `${radius}px`,
        "--demo-font": theme.font,
      } as React.CSSProperties}
    >
      <header className="demo-header">
        <div>
          <h1>@seventwo-studio/block-editor</h1>
          <p>React UI, schema, markdown, and operation data in one portable package.</p>
        </div>
        <a href="https://github.com/seventwo-studio/block-editor">GitHub</a>
      </header>

      <section className="demo-grid">
        <div className="editor-panel">
          <div className="panel-heading">
            <span>Browser editor</span>
            <span>{blocks.length} blocks</span>
          </div>
          <BlockEditor
            value={blocks}
            onChange={setBlocks}
            onOperation={handleOperation}
            placeholder="Type / for commands"
            autoFocus
            className="demo-editor"
            style={editorStyle}
          />
        </div>

        <aside className="inspector">
          <section>
            <h2>Themes</h2>
            <div className="theme-buttons">
              {(Object.keys(themes) as ThemeKey[]).map((key) => (
                <button
                  key={key}
                  type="button"
                  className={key === themeKey ? "active" : ""}
                  onClick={() => selectTheme(key)}
                >
                  {themes[key].name}
                </button>
              ))}
            </div>
            <label>
              Accent
              <input
                type="color"
                value={accent}
                onChange={(event) => setAccent(event.target.value)}
              />
            </label>
            <label>
              Radius
              <input
                type="range"
                min="0"
                max="24"
                value={radius}
                onChange={(event) => setRadius(Number(event.target.value))}
              />
            </label>
          </section>

          <section>
            <h2>Operations</h2>
            <div className="operation-list">
              {operations.length === 0 ? (
                <p className="empty">Edit the document to see operations.</p>
              ) : (
                operations.map(({ id, operation }) => (
                  <pre key={id}>
                    {JSON.stringify(operation, null, 2)}
                  </pre>
                ))
              )}
            </div>
          </section>

          <section>
            <h2>CRDT state</h2>
            <pre>{JSON.stringify(crdt.operations.slice(-6), null, 2)}</pre>
          </section>

          <section>
            <h2>Markdown</h2>
            <pre>{markdown}</pre>
          </section>
        </aside>
      </section>
    </main>
  )
}

function applyUiOperation(
  current: BlockEditorCrdtState,
  operation: BlockEditorUiOperation,
  blocks: Block[],
): BlockEditorCrdtState {
  if (operation.type === "insert") {
    return applyOperation(current, insertBlockOperation(current, operation.block))
  }
  if (operation.type === "update" || operation.type === "replace") {
    return applyOperation(current, updateBlockOperation(current, operation.block))
  }
  if (operation.type === "move") {
    return applyOperation(
      current,
      moveBlockOperation(current, operation.block.id, operation.to),
    )
  }
  if (operation.type === "delete") {
    return applyOperation(current, deleteBlockOperation(current, operation.block.id))
  }
  if (operation.type === "delete-many") {
    return operation.blocks.reduce(
      (state, block) =>
        applyOperation(state, deleteBlockOperation(state, block.id)),
      current,
    )
  }
  if (operation.type === "reorder") {
    return createCrdtState("demo", operation.blocks)
  }
  return createCrdtState("demo", blocks)
}
