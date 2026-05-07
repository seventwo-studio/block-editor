import {
  type Block,
  CODE_LANGUAGES,
  type SimpleBlockType,
  SLASH_COMMANDS,
  filterSlashCommands,
  getBlockText,
  getCodeLanguage,
  getEnterBehavior,
  getListPrefix,
  getPlaceholder,
  getSlashQuery,
  insertAfter,
  isBlockEmpty,
  makeBlock,
  parseMarkdownToBlocks,
  removeFromArray,
  serializeBlocksToMarkdown,
  setBlockText,
  toSimpleType,
  transformShortcut,
} from "./index.js"
import {
  type KeyboardEvent,
  type CSSProperties,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react"

export type BlockEditorUiOperation =
  | { type: "insert"; block: Block; afterId?: string }
  | { type: "update"; before: Block; block: Block }
  | { type: "replace"; before: Block; block: Block }
  | { type: "move"; block: Block; from: number; to: number }
  | { type: "delete"; block: Block }
  | { type: "markdown"; blocks: Block[] }

export interface BlockEditorProps {
  value: Block[]
  onChange: (blocks: Block[]) => void
  onOperation?: (operation: BlockEditorUiOperation, blocks: Block[]) => void
  placeholder?: string
  autoFocus?: boolean
  className?: string
  compact?: boolean
  style?: CSSProperties
}

export function BlockEditor({
  value,
  onChange,
  onOperation,
  placeholder = "Write something...",
  autoFocus = false,
  className,
  compact = false,
  style,
}: BlockEditorProps) {
  const [blocks, setBlocksRaw] = useState<Block[]>(() =>
    value.length > 0 ? value : [makeBlock("paragraph")],
  )
  const [focusedBlockId, setFocusedBlockId] = useState<string | null>(null)
  const [mode, setMode] = useState<"blocks" | "markdown">("blocks")
  const [markdownDraft, setMarkdownDraft] = useState("")
  const inputRefs = useRef<Record<string, HTMLTextAreaElement | null>>({})
  const blocksRef = useRef(blocks)
  blocksRef.current = blocks

  useEffect(() => {
    if (JSON.stringify(value) === JSON.stringify(blocksRef.current)) return
    setBlocksRaw(value.length > 0 ? value : [makeBlock("paragraph")])
  }, [value])

  function commit(
    next: Block[],
    operation?: BlockEditorUiOperation,
    focusBlockId?: string,
  ) {
    blocksRef.current = next
    setBlocksRaw(next)
    onChange(next)
    if (operation) onOperation?.(operation, next)
    if (focusBlockId) {
      setFocusedBlockId(focusBlockId)
      requestAnimationFrame(() => inputRefs.current[focusBlockId]?.focus())
    }
  }

  function updateText(block: Block, text: string) {
    const shortcut = transformShortcut(text, block)
    const replacement = shortcut?.block
      ? { ...shortcut.block, id: block.id }
      : setBlockText(block, text)
    commit(
      blocks.map((item) => (item.id === block.id ? replacement : item)),
      {
        type: shortcut?.block ? "replace" : "update",
        before: block,
        block: replacement,
      },
    )
  }

  function replaceType(block: Block, type: SimpleBlockType) {
    const command = SLASH_COMMANDS.find((item) => item.id === type)
    if (!command) return
    const oldText = getBlockText(block)
    const nextBlock =
      type === "divider" || type === "table"
        ? { ...command.apply(), id: block.id }
        : { ...setBlockText(command.apply(), oldText), id: block.id }
    commit(
      blocks.map((item) => (item.id === block.id ? nextBlock : item)),
      { type: "replace", before: block, block: nextBlock },
      nextBlock.id,
    )
  }

  function insertBlock(afterId: string, type: SimpleBlockType = "paragraph") {
    const block = makeBlock(type)
    commit(insertAfter(blocks, afterId, block), {
      type: "insert",
      block,
      afterId,
    }, block.id)
  }

  function deleteBlock(block: Block) {
    commit(removeFromArray(blocks, block.id), { type: "delete", block })
  }

  function moveBlock(block: Block, direction: -1 | 1) {
    const from = blocks.findIndex((item) => item.id === block.id)
    const to = from + direction
    if (from < 0 || to < 0 || to >= blocks.length) return
    const next = [...blocks]
    const [moving] = next.splice(from, 1)
    next.splice(to, 0, moving)
    commit(next, { type: "move", block, from, to }, block.id)
  }

  function applyMarkdown() {
    const next = parseMarkdownToBlocks(markdownDraft)
    commit(next, { type: "markdown", blocks: next }, next[0]?.id)
    setMode("blocks")
  }

  function enterMarkdown() {
    setMarkdownDraft(serializeBlocksToMarkdown(blocks))
    setMode("markdown")
  }

  if (mode === "markdown") {
    return (
      <section
        className={[
          "s2be",
          compact ? "s2be--compact" : "",
          className ?? "",
        ].join(" ")}
        style={style}
      >
        <div className="s2be-toolbar">
          <button type="button" onClick={applyMarkdown}>
            Apply markdown
          </button>
          <button type="button" onClick={() => setMode("blocks")}>
            Cancel
          </button>
        </div>
        <textarea
          className="s2be-markdown"
          value={markdownDraft}
          onChange={(event) => setMarkdownDraft(event.target.value)}
          spellCheck={false}
        />
      </section>
    )
  }

  return (
    <section
      className={["s2be", compact ? "s2be--compact" : "", className ?? ""]
        .filter(Boolean)
        .join(" ")}
      style={style}
    >
      <div
        className="s2be-toolbar"
        role="toolbar"
        aria-label="Block editor toolbar"
      >
        <button type="button" onClick={() => insertBlock(blocks.at(-1)?.id ?? "")}>
          Add block
        </button>
        <button type="button" onClick={enterMarkdown}>
          Markdown
        </button>
      </div>
      <div className="s2be-document">
        {blocks.map((block, index) => (
          <BlockRow
            key={block.id}
            block={block}
            blocks={blocks}
            index={index}
            focused={focusedBlockId === block.id}
            placeholder={placeholder}
            autoFocus={autoFocus && index === 0}
            inputRef={(node) => {
              inputRefs.current[block.id] = node
            }}
            onFocus={() => setFocusedBlockId(block.id)}
            onUpdateText={(text) => updateText(block, text)}
            onReplace={(type) => replaceType(block, type)}
            onInsert={(type) => insertBlock(block.id, type)}
            onDelete={() => deleteBlock(block)}
            onMove={(direction) => moveBlock(block, direction)}
            onToggleTodo={() => {
              if (block.type !== "list" || block.style !== "todo") return
              const nextBlock: Block = {
                ...block,
                items: block.items.map((item) => ({
                  ...item,
                  checked: !item.checked,
                })),
              }
              commit(
                blocks.map((item) => (item.id === block.id ? nextBlock : item)),
                { type: "update", before: block, block: nextBlock },
              )
            }}
            onTableCell={(rowIndex, cellIndex, text) => {
              if (block.type !== "table") return
              const nextBlock: Block = {
                ...block,
                rows: block.rows.map((row, rowI) =>
                  rowI === rowIndex
                    ? {
                        ...row,
                        cells: row.cells.map((cell, cellI) =>
                          cellI === cellIndex
                            ? {
                                ...cell,
                                content: text
                                  ? [{ type: "text", text, marks: [] }]
                                  : [],
                              }
                            : cell,
                        ),
                      }
                    : row,
                ),
              }
              commit(
                blocks.map((item) => (item.id === block.id ? nextBlock : item)),
                { type: "update", before: block, block: nextBlock },
              )
            }}
            onCodeLanguage={(language) => {
              if (block.type !== "code") return
              const nextBlock: Block = { ...block, language }
              commit(
                blocks.map((item) => (item.id === block.id ? nextBlock : item)),
                { type: "update", before: block, block: nextBlock },
              )
            }}
          />
        ))}
      </div>
    </section>
  )
}

function BlockRow({
  block,
  blocks,
  index,
  focused,
  placeholder,
  autoFocus,
  inputRef,
  onFocus,
  onUpdateText,
  onReplace,
  onInsert,
  onDelete,
  onMove,
  onToggleTodo,
  onTableCell,
  onCodeLanguage,
}: {
  block: Block
  blocks: Block[]
  index: number
  focused: boolean
  placeholder: string
  autoFocus: boolean
  inputRef: (node: HTMLTextAreaElement | null) => void
  onFocus: () => void
  onUpdateText: (text: string) => void
  onReplace: (type: SimpleBlockType) => void
  onInsert: (type: SimpleBlockType) => void
  onDelete: () => void
  onMove: (direction: -1 | 1) => void
  onToggleTodo: () => void
  onTableCell: (rowIndex: number, cellIndex: number, text: string) => void
  onCodeLanguage: (language: string) => void
}) {
  const simpleType = toSimpleType(block)
  const slashQuery = focused ? getSlashQuery(block) : null
  const visibleCommands = useMemo(
    () => filterSlashCommands(slashQuery),
    [slashQuery],
  )
  const text = getBlockText(block)
  const prefix = getListPrefix(block, blocks, index)
  const canConvert = simpleType !== "divider" && simpleType !== "table"

  function handleKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && !event.shiftKey && block.type !== "code") {
      event.preventDefault()
      const behavior = getEnterBehavior(block)
      if (behavior.action === "replace") onReplace(behavior.type)
      else onInsert(behavior.type)
    }
    if (event.key === "Backspace" && isBlockEmpty(block)) {
      event.preventDefault()
      onDelete()
    }
  }

  return (
    <article className="s2be-block" data-type={simpleType}>
      <div className="s2be-block-tools">
        <button type="button" onClick={() => onInsert("paragraph")}>
          +
        </button>
        <button type="button" onClick={() => onMove(-1)} disabled={index === 0}>
          ↑
        </button>
        <button
          type="button"
          onClick={() => onMove(1)}
          disabled={index === blocks.length - 1}
        >
          ↓
        </button>
      </div>
      <div className="s2be-block-main">
        <div className="s2be-block-meta">
          <select
            value={simpleType}
            onChange={(event) => onReplace(event.target.value as SimpleBlockType)}
            aria-label="Block type"
          >
            {SLASH_COMMANDS.map((command) => (
              <option key={command.id} value={command.id}>
                {command.title}
              </option>
            ))}
          </select>
          <button type="button" onClick={onDelete}>
            Delete
          </button>
        </div>
        <div className="s2be-block-content">
          {prefix !== null ? <span className="s2be-prefix">{prefix}</span> : null}
          {block.type === "list" && block.style === "todo" ? (
            <input
              className="s2be-checkbox"
              type="checkbox"
              checked={block.items[0]?.checked ?? false}
              onChange={onToggleTodo}
              aria-label="Toggle todo"
            />
          ) : null}
          <EditableBlock
            block={block}
            text={text}
            placeholder={getPlaceholder(simpleType, placeholder)}
            autoFocus={autoFocus}
            inputRef={inputRef}
            onFocus={onFocus}
            onKeyDown={handleKeyDown}
            onUpdateText={onUpdateText}
            onTableCell={onTableCell}
            onCodeLanguage={onCodeLanguage}
          />
        </div>
        {visibleCommands.length > 0 && canConvert ? (
          <div className="s2be-slash-menu">
            {visibleCommands.map((command) => (
              <button
                key={command.id}
                type="button"
                onMouseDown={(event) => {
                  event.preventDefault()
                  onReplace(command.id)
                }}
              >
                <strong>{command.title}</strong>
                <span>{command.description}</span>
              </button>
            ))}
          </div>
        ) : null}
      </div>
    </article>
  )
}

function EditableBlock({
  block,
  text,
  placeholder,
  autoFocus,
  inputRef,
  onFocus,
  onKeyDown,
  onUpdateText,
  onTableCell,
  onCodeLanguage,
}: {
  block: Block
  text: string
  placeholder: string
  autoFocus: boolean
  inputRef: (node: HTMLTextAreaElement | null) => void
  onFocus: () => void
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) => void
  onUpdateText: (text: string) => void
  onTableCell: (rowIndex: number, cellIndex: number, text: string) => void
  onCodeLanguage: (language: string) => void
}) {
  if (block.type === "divider") return <hr className="s2be-divider" />

  if (block.type === "table") {
    return (
      <div className="s2be-table-wrap">
        <table className="s2be-table">
          <tbody>
            {block.rows.map((row, rowIndex) => (
              <tr key={row.id}>
                {row.cells.map((cell, cellIndex) => (
                  <td key={cell.id}>
                    <input
                      value={getBlockText({
                        id: cell.id,
                        type: "paragraph",
                        content: cell.content,
                      })}
                      onFocus={onFocus}
                      onChange={(event) =>
                        onTableCell(rowIndex, cellIndex, event.target.value)
                      }
                      placeholder={cell.header ? "Column" : ""}
                    />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    )
  }

  if (block.type === "code") {
    return (
      <div className="s2be-code">
        <select
          value={getCodeLanguage(block.language).id}
          onChange={(event) => onCodeLanguage(event.target.value)}
          aria-label="Code language"
        >
          {CODE_LANGUAGES.map((language) => (
            <option key={language.id} value={language.id}>
              {language.label}
            </option>
          ))}
        </select>
        <AutoGrowTextarea
          value={block.code}
          placeholder={placeholder}
          autoFocus={autoFocus}
          className="s2be-input s2be-input--code"
          inputRef={inputRef}
          onFocus={onFocus}
          onKeyDown={onKeyDown}
          onChange={onUpdateText}
          spellCheck={false}
        />
      </div>
    )
  }

  return (
    <AutoGrowTextarea
      value={text}
      placeholder={placeholder}
      autoFocus={autoFocus}
      className="s2be-input"
      inputRef={inputRef}
      onFocus={onFocus}
      onKeyDown={onKeyDown}
      onChange={onUpdateText}
    />
  )
}

function AutoGrowTextarea({
  value,
  placeholder,
  autoFocus,
  className,
  inputRef,
  onFocus,
  onKeyDown,
  onChange,
  spellCheck,
}: {
  value: string
  placeholder: string
  autoFocus: boolean
  className: string
  inputRef: (node: HTMLTextAreaElement | null) => void
  onFocus: () => void
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) => void
  onChange: (value: string) => void
  spellCheck?: boolean
}) {
  const localRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    const node = localRef.current
    if (!node) return
    node.style.height = "0px"
    node.style.height = `${node.scrollHeight}px`
  })

  useEffect(() => {
    if (autoFocus) localRef.current?.focus()
  }, [autoFocus])

  return (
    <textarea
      ref={(node) => {
        localRef.current = node
        inputRef(node)
      }}
      className={className}
      value={value}
      placeholder={placeholder}
      rows={1}
      wrap="soft"
      spellCheck={spellCheck}
      onFocus={onFocus}
      onKeyDown={onKeyDown}
      onChange={(event) => onChange(event.target.value)}
    />
  )
}
