import {
  type Block,
  CALLOUT_COLORS,
  CODE_LANGUAGES,
  type SimpleBlockType,
  SLASH_COMMANDS,
  calloutColorStyle,
  filterSlashCommands,
  getBlockText,
  getCodeLanguage,
  getConvertibleTypes,
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
  type CSSProperties,
  type KeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react"

// ---------------------------------------------------------------------------
// Operation log — one event per discrete user-visible change. Multi-block
// drags emit a single `reorder`; multi-block deletions emit a single
// `delete-many` so consumers can replay them as a batch.
// ---------------------------------------------------------------------------

export type BlockEditorUiOperation =
  | { type: "insert"; block: Block; afterId?: string }
  | { type: "update"; before: Block; block: Block }
  | { type: "replace"; before: Block; block: Block }
  | { type: "move"; block: Block; from: number; to: number }
  | { type: "reorder"; blocks: Block[] }
  | { type: "delete"; block: Block }
  | { type: "delete-many"; blocks: Block[] }
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

type EditableRef = HTMLTextAreaElement | HTMLInputElement | null

// ---------------------------------------------------------------------------
// Inline SVG icons — kept in-package so consumers don't pull in an icon lib.
// ---------------------------------------------------------------------------

interface IconProps {
  className?: string
}

function Icon({
  children,
  className,
  viewBox = "0 0 24 24",
}: {
  children: ReactNode
  className?: string
  viewBox?: string
}) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox={viewBox}
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {children}
    </svg>
  )
}

const GripIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <circle cx="9" cy="6" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="15" cy="6" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="9" cy="12" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="15" cy="12" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="9" cy="18" r="0.9" fill="currentColor" stroke="none" />
    <circle cx="15" cy="18" r="0.9" fill="currentColor" stroke="none" />
  </Icon>
)
const ArrowUpIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M12 19V5" />
    <path d="m5 12 7-7 7 7" />
  </Icon>
)
const ArrowDownIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M12 5v14" />
    <path d="m19 12-7 7-7-7" />
  </Icon>
)
const TrashIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M3 6h18" />
    <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
    <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
  </Icon>
)
const CheckIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M20 6 9 17l-5-5" />
  </Icon>
)
const ChevronDownIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="m6 9 6 6 6-6" />
  </Icon>
)
const PlusIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M12 5v14" />
    <path d="M5 12h14" />
  </Icon>
)
const Heading1Icon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M4 4v16" />
    <path d="M12 4v16" />
    <path d="M4 12h8" />
    <path d="M17 8h2v12" />
  </Icon>
)
const Heading2Icon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M4 4v16" />
    <path d="M12 4v16" />
    <path d="M4 12h8" />
    <path d="M16 9a3 3 0 0 1 6 0c0 1.5-1 2.5-2.5 4L16 19h6" />
  </Icon>
)
const Heading3Icon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M4 4v16" />
    <path d="M12 4v16" />
    <path d="M4 12h8" />
    <path d="M16 8a3 3 0 0 1 6 0c0 1.5-1 2.5-2.5 2.5C21 10.5 22 11.5 22 13a3 3 0 0 1-6 0" />
  </Icon>
)
const ListIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M9 6h12" />
    <path d="M9 12h12" />
    <path d="M9 18h12" />
    <circle cx="4" cy="6" r="1" fill="currentColor" stroke="none" />
    <circle cx="4" cy="12" r="1" fill="currentColor" stroke="none" />
    <circle cx="4" cy="18" r="1" fill="currentColor" stroke="none" />
  </Icon>
)
const ListOrderedIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M10 6h11" />
    <path d="M10 12h11" />
    <path d="M10 18h11" />
    <path d="M4 6h1v4" />
    <path d="M4 10h2" />
    <path d="M6 18H4c0-1 2-2 2-3s-1-1.5-2-1" />
  </Icon>
)
const ListTodoIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <rect x="3" y="5" width="6" height="6" rx="1" />
    <path d="m4 8 1 1 2-2" />
    <rect x="3" y="13" width="6" height="6" rx="1" />
    <path d="M13 6h8" />
    <path d="M13 16h8" />
  </Icon>
)
const QuoteIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M3 21c3 0 6-2 6-8V5H3v6h3c0 2-1 4-3 4z" />
    <path d="M15 21c3 0 6-2 6-8V5h-6v6h3c0 2-1 4-3 4z" />
  </Icon>
)
const CalloutIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="m12 3 10 18H2L12 3z" />
    <path d="M12 9v5" />
    <path d="M12 17h.01" />
  </Icon>
)
const CodeIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="m16 18 6-6-6-6" />
    <path d="m8 6-6 6 6 6" />
  </Icon>
)
const DividerIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M5 12h14" />
  </Icon>
)
const TableIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <rect x="3" y="4" width="18" height="16" rx="1.5" />
    <path d="M3 10h18" />
    <path d="M3 16h18" />
    <path d="M9 4v16" />
    <path d="M15 4v16" />
  </Icon>
)
const TextIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <path d="M5 4h14" />
    <path d="M12 4v16" />
    <path d="M9 20h6" />
  </Icon>
)
const MarkdownIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <rect x="3" y="6" width="18" height="12" rx="1.5" />
    <path d="M7 15v-6l2 3 2-3v6" />
    <path d="M16 9v6" />
    <path d="m13 12 3 3 3-3" />
  </Icon>
)
const BlocksIcon = ({ className }: IconProps) => (
  <Icon className={className}>
    <rect x="3" y="3" width="8" height="8" rx="1" />
    <rect x="13" y="3" width="8" height="8" rx="1" />
    <rect x="3" y="13" width="8" height="8" rx="1" />
    <rect x="13" y="13" width="8" height="8" rx="1" />
  </Icon>
)

const SLASH_COMMAND_ICONS: Record<SimpleBlockType, (p: IconProps) => ReactNode> = {
  paragraph: TextIcon,
  heading1: Heading1Icon,
  heading2: Heading2Icon,
  heading3: Heading3Icon,
  bullet: ListIcon,
  ordered: ListOrderedIcon,
  todo: ListTodoIcon,
  quote: QuoteIcon,
  callout: CalloutIcon,
  code: CodeIcon,
  divider: DividerIcon,
  table: TableIcon,
}

// ---------------------------------------------------------------------------
// AutoGrowTextarea — used everywhere except the table grid
// ---------------------------------------------------------------------------

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

  // biome-ignore lint/correctness/useExhaustiveDependencies: scrollHeight depends on the value, so we must recompute when it changes
  useLayoutEffect(() => {
    const node = localRef.current
    if (!node) return
    const recompute = () => {
      node.style.height = "0px"
      node.style.height = `${node.scrollHeight}px`
    }
    recompute()
    const parent = node.parentElement
    if (!parent || typeof ResizeObserver === "undefined") return
    const observer = new ResizeObserver(recompute)
    observer.observe(parent)
    return () => observer.disconnect()
  }, [value])

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

// ---------------------------------------------------------------------------
// Popover — minimal, click-outside aware. Used for the grip menu and code
// language picker so we don't pull in an external popover library.
// ---------------------------------------------------------------------------

function Popover({
  open,
  onClose,
  children,
}: {
  open: boolean
  onClose: () => void
  children: ReactNode
}) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onPointerDown(event: PointerEvent) {
      if (!ref.current) return
      if (!ref.current.contains(event.target as Node)) onClose()
    }
    function onKey(event: globalThis.KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("pointerdown", onPointerDown)
    document.addEventListener("keydown", onKey)
    return () => {
      document.removeEventListener("pointerdown", onPointerDown)
      document.removeEventListener("keydown", onKey)
    }
  }, [open, onClose])

  if (!open) return null

  return (
    <div ref={ref} className="s2be-popover" role="menu">
      {children}
    </div>
  )
}

// ---------------------------------------------------------------------------
// CodeBlockView — bordered code block with a language picker.
// ---------------------------------------------------------------------------

function CodeBlockView({
  block,
  text,
  placeholder,
  autoFocus,
  inputRef,
  onFocus,
  onKeyDown,
  onChangeText,
  onChangeLanguage,
}: {
  block: Block & { type: "code" }
  text: string
  placeholder: string
  autoFocus: boolean
  inputRef: (node: HTMLTextAreaElement | null) => void
  onFocus: () => void
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement>) => void
  onChangeText: (text: string) => void
  onChangeLanguage: (id: string) => void
}) {
  const [open, setOpen] = useState(false)
  const lang = getCodeLanguage(block.language)

  return (
    <div className="s2be-code">
      <div className="s2be-code-header">
        <button
          type="button"
          className="s2be-code-language"
          onClick={() => setOpen((v) => !v)}
          aria-haspopup="menu"
          aria-expanded={open}
        >
          <span>{lang.label}</span>
          <ChevronDownIcon className="s2be-icon-xs" />
        </button>
        <Popover open={open} onClose={() => setOpen(false)}>
          <div className="s2be-popover-label">Language</div>
          <div className="s2be-popover-scroll">
            {CODE_LANGUAGES.map((l) => (
              <button
                key={l.id}
                type="button"
                role="menuitem"
                className="s2be-popover-item"
                onClick={() => {
                  onChangeLanguage(l.id)
                  setOpen(false)
                }}
              >
                <span>{l.label}</span>
                {l.id === lang.id ? (
                  <CheckIcon className="s2be-icon-sm s2be-popover-check" />
                ) : null}
              </button>
            ))}
          </div>
        </Popover>
      </div>
      <AutoGrowTextarea
        value={text}
        placeholder={placeholder}
        autoFocus={autoFocus}
        className="s2be-input s2be-input--code"
        inputRef={inputRef}
        onFocus={onFocus}
        onKeyDown={onKeyDown}
        onChange={onChangeText}
        spellCheck={false}
      />
    </div>
  )
}

// ---------------------------------------------------------------------------
// TableBlockView — editable table grid with column resize and a per-row /
// per-column add/remove menu.
// ---------------------------------------------------------------------------

function TableBlockView({
  block,
  inputRef,
  onFocus,
  onKeyDown,
  onUpdateCell,
  onAddRow,
  onAddColumn,
  onRemoveRow,
  onRemoveColumn,
  onResize,
}: {
  block: Block & { type: "table" }
  inputRef: (node: HTMLInputElement | null) => void
  onFocus: () => void
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void
  onUpdateCell: (rowIdx: number, cellIdx: number, text: string) => void
  onAddRow: () => void
  onAddColumn: () => void
  onRemoveRow: (rowIdx: number) => void
  onRemoveColumn: (colIdx: number) => void
  onResize: (newWidths: number[]) => void
}) {
  const colCount = block.rows[0]?.cells.length ?? 1
  const tableRef = useRef<HTMLTableElement>(null)

  const widths =
    block.columnWidths?.length === colCount
      ? block.columnWidths
      : Array.from({ length: colCount }, () => 100 / colCount)

  function handleResizeStart(e: ReactMouseEvent, colIdx: number) {
    e.preventDefault()
    e.stopPropagation()
    const table = tableRef.current
    if (!table) return
    const tableWidth = table.offsetWidth
    const startX = e.clientX
    const startWidths = [...widths]

    function onMove(ev: MouseEvent) {
      const dx = ev.clientX - startX
      const deltaPct = (dx / tableWidth) * 100
      const minPct = 10
      let leftW = startWidths[colIdx] + deltaPct
      let rightW = startWidths[colIdx + 1] - deltaPct
      if (leftW < minPct) {
        leftW = minPct
        rightW = startWidths[colIdx] + startWidths[colIdx + 1] - minPct
      }
      if (rightW < minPct) {
        rightW = minPct
        leftW = startWidths[colIdx] + startWidths[colIdx + 1] - minPct
      }
      const next = [...startWidths]
      next[colIdx] = leftW
      next[colIdx + 1] = rightW
      onResize(next)
    }

    function onUp() {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
    }

    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
  }

  const canRemoveRow = block.rows.length > 2
  const canRemoveColumn = colCount > 1

  return (
    <div className="s2be-table-wrap">
      <table
        ref={tableRef}
        className="s2be-table"
        style={{ tableLayout: "fixed" }}
      >
        <colgroup>
          {widths.map((w, i) => (
            <col
              key={block.rows[0]?.cells[i]?.id ?? i}
              style={{ width: `${w}%` }}
            />
          ))}
        </colgroup>
        <tbody>
          {block.rows.map((row, rowIdx) => (
            <tr key={row.id}>
              {row.cells.map((cell, cellIdx) => (
                <td key={cell.id} className={rowIdx === 0 ? "s2be-th" : ""}>
                  <input
                    ref={
                      rowIdx === 0 && cellIdx === 0 ? inputRef : undefined
                    }
                    value={getBlockText({
                      id: cell.id,
                      type: "paragraph",
                      content: cell.content,
                    })}
                    onFocus={onFocus}
                    onKeyDown={onKeyDown}
                    onChange={(event) =>
                      onUpdateCell(rowIdx, cellIdx, event.target.value)
                    }
                    placeholder={rowIdx === 0 ? "Column" : ""}
                  />
                  {cellIdx < colCount - 1 ? (
                    <span
                      className="s2be-col-resize"
                      onMouseDown={(event) =>
                        handleResizeStart(event, cellIdx)
                      }
                      aria-hidden="true"
                    />
                  ) : null}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="s2be-table-actions">
        <button type="button" onClick={onAddRow}>
          <PlusIcon className="s2be-icon-sm" />
          Row
        </button>
        <button type="button" onClick={onAddColumn}>
          <PlusIcon className="s2be-icon-sm" />
          Column
        </button>
        {canRemoveRow ? (
          <button
            type="button"
            onClick={() => onRemoveRow(block.rows.length - 1)}
          >
            <TrashIcon className="s2be-icon-sm" />
            Last row
          </button>
        ) : null}
        {canRemoveColumn ? (
          <button
            type="button"
            onClick={() => onRemoveColumn(colCount - 1)}
          >
            <TrashIcon className="s2be-icon-sm" />
            Last column
          </button>
        ) : null}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// CalloutColorPicker — the small swatch row that lives next to a callout.
// ---------------------------------------------------------------------------

function CalloutColorPicker({
  value,
  onChange,
}: {
  value: string | undefined
  onChange: (color: string | undefined) => void
}) {
  const [open, setOpen] = useState(false)
  const swatchColor = value ?? "#9aa0a6"
  return (
    <div className="s2be-callout-color">
      <button
        type="button"
        className="s2be-callout-color-button"
        onClick={() => setOpen((v) => !v)}
        aria-label="Callout color"
        style={{ backgroundColor: swatchColor }}
      />
      <Popover open={open} onClose={() => setOpen(false)}>
        <div className="s2be-popover-label">Color</div>
        <div className="s2be-callout-swatches">
          <button
            type="button"
            className="s2be-callout-swatch s2be-callout-swatch--default"
            onClick={() => {
              onChange(undefined)
              setOpen(false)
            }}
            aria-label="Default"
          >
            {value ? null : <CheckIcon className="s2be-icon-sm" />}
          </button>
          {CALLOUT_COLORS.map((color) => (
            <button
              key={color}
              type="button"
              className="s2be-callout-swatch"
              style={{ backgroundColor: color }}
              onClick={() => {
                onChange(color)
                setOpen(false)
              }}
              aria-label={`Color ${color}`}
            >
              {value === color ? <CheckIcon className="s2be-icon-sm" /> : null}
            </button>
          ))}
        </div>
      </Popover>
    </div>
  )
}

// ---------------------------------------------------------------------------
// BlockEditor
// ---------------------------------------------------------------------------

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
  const [mode, setMode] = useState<"blocks" | "markdown">("blocks")
  const [markdownDraft, setMarkdownDraft] = useState("")
  const [focusedBlockId, setFocusedBlockId] = useState<string | null>(null)
  const [slashIndex, setSlashIndex] = useState(0)
  const [draggedBlockId, setDraggedBlockId] = useState<string | null>(null)
  const [dropIndex, setDropIndex] = useState<number | null>(null)
  const [openMenuBlockId, setOpenMenuBlockId] = useState<string | null>(null)
  const [selectedBlockIds, setSelectedBlockIds] = useState<Set<string>>(
    () => new Set(),
  )
  const [marquee, setMarquee] = useState<{
    startX: number
    startY: number
    currentX: number
    currentY: number
  } | null>(null)

  const inputRefs = useRef<Record<string, EditableRef>>({})
  const blocksRef = useRef(blocks)
  blocksRef.current = blocks
  const onChangeRef = useRef(onChange)
  onChangeRef.current = onChange
  const onOperationRef = useRef(onOperation)
  onOperationRef.current = onOperation
  const containerRef = useRef<HTMLDivElement>(null)
  const markdownRef = useRef<HTMLTextAreaElement>(null)
  const lastSyncedRef = useRef(value)
  const shouldAutofocusRef = useRef(autoFocus)
  const gripPressedRef = useRef(false)
  const isDraggingRef = useRef(false)
  const lastSelectedIndexRef = useRef<number | null>(null)
  const selectionHeadRef = useRef<number | null>(null)
  const selectedBlockIdsRef = useRef(selectedBlockIds)
  selectedBlockIdsRef.current = selectedBlockIds

  // Sync from parent without re-emitting our own changes.
  useEffect(() => {
    if (value === lastSyncedRef.current) return
    if (JSON.stringify(value) === JSON.stringify(lastSyncedRef.current)) return
    const next = value.length > 0 ? value : [makeBlock("paragraph")]
    lastSyncedRef.current = next
    blocksRef.current = next
    setBlocksRaw(next)
  }, [value])

  function commit(
    next: Block[],
    operation?: BlockEditorUiOperation,
    focusBlockId?: string,
  ) {
    blocksRef.current = next
    lastSyncedRef.current = next
    setBlocksRaw(next)
    onChangeRef.current(next)
    if (operation) onOperationRef.current?.(operation, next)
    if (focusBlockId) {
      setFocusedBlockId(focusBlockId)
      shouldAutofocusRef.current = true
    }
  }

  // --- Block operations -----------------------------------------------------

  function updateText(block: Block, text: string) {
    clearSelection()
    setSlashIndex(0)
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
    const text = getBlockText(block)
    const fresh = command.apply()
    const next: Block =
      type === "divider" || type === "table"
        ? { ...fresh, id: block.id }
        : { ...setBlockText(fresh, text), id: block.id }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "replace", before: block, block: next },
      next.id,
    )
  }

  function insertBlock(afterId: string, type: SimpleBlockType = "paragraph") {
    const block = makeBlock(type)
    commit(
      insertAfter(blocks, afterId, block),
      { type: "insert", block, afterId },
      block.id,
    )
  }

  function deleteBlock(block: Block) {
    const idx = blocks.findIndex((b) => b.id === block.id)
    const focusTarget = blocks[idx - 1] ?? blocks[idx + 1]
    commit(
      removeFromArray(blocks, block.id),
      { type: "delete", block },
      focusTarget?.id,
    )
  }

  function deleteBlocks(ids: string[]) {
    if (ids.length === 0) return
    if (ids.length === 1) {
      const target = blocks.find((b) => b.id === ids[0])
      if (target) deleteBlock(target)
      return
    }
    const idsSet = new Set(ids)
    const removed = blocks.filter((b) => idsSet.has(b.id))
    const firstIdx = blocks.findIndex((b) => idsSet.has(b.id))
    const remaining = blocks.filter((b) => !idsSet.has(b.id))
    const next =
      remaining.length > 0 ? remaining : [makeBlock("paragraph")]
    const focusTarget =
      next[Math.max(0, Math.min(firstIdx - 1, next.length - 1))] ?? next[0]
    setSelectedBlockIds(new Set())
    lastSelectedIndexRef.current = null
    selectionHeadRef.current = null
    commit(next, { type: "delete-many", blocks: removed }, focusTarget?.id)
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

  function moveBlocksToIndex(sourceIds: string[], targetIdx: number) {
    if (sourceIds.length === 0) return
    if (sourceIds.length === 1) {
      const block = blocks.find((b) => b.id === sourceIds[0])
      if (!block) return
      const from = blocks.findIndex((b) => b.id === block.id)
      if (targetIdx === from || targetIdx === from + 1) return
      const adjusted = from < targetIdx ? targetIdx - 1 : targetIdx
      const next = [...blocks]
      const [moving] = next.splice(from, 1)
      next.splice(adjusted, 0, moving)
      commit(next, { type: "move", block, from, to: adjusted }, block.id)
      return
    }
    const idsSet = new Set(sourceIds)
    const moving = blocks.filter((b) => idsSet.has(b.id))
    if (moving.length === 0) return
    const without = blocks.filter((b) => !idsSet.has(b.id))
    let adjustedIdx = targetIdx
    for (let i = 0; i < targetIdx && i < blocks.length; i++) {
      if (idsSet.has(blocks[i].id)) adjustedIdx--
    }
    adjustedIdx = Math.max(0, Math.min(adjustedIdx, without.length))
    const next = [
      ...without.slice(0, adjustedIdx),
      ...moving,
      ...without.slice(adjustedIdx),
    ]
    commit(next, { type: "reorder", blocks: next })
  }

  function applySlashCommand(block: Block, commandIndex: number) {
    const visible = filterSlashCommands(getSlashQuery(block))
    const cmd = visible[commandIndex]
    if (!cmd) return
    const fresh = cmd.apply()
    const next: Block = { ...fresh, id: block.id }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "replace", before: block, block: next },
      next.id,
    )
    setSlashIndex(0)
  }

  function toggleTodo(block: Block) {
    if (block.type !== "list" || block.style !== "todo") return
    const next: Block = {
      ...block,
      items: block.items.map((item) => ({
        ...item,
        checked: !item.checked,
      })),
    }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function setCalloutColor(block: Block, color: string | undefined) {
    if (block.type !== "callout") return
    const next: Block = { ...block, color }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function setCodeLanguage(block: Block, language: string) {
    if (block.type !== "code") return
    const next: Block = { ...block, language }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  // --- Table operations -----------------------------------------------------

  function updateTableCell(
    block: Block,
    rowIdx: number,
    cellIdx: number,
    text: string,
  ) {
    if (block.type !== "table") return
    const next: Block = {
      ...block,
      rows: block.rows.map((row, rIdx) =>
        rIdx === rowIdx
          ? {
              ...row,
              cells: row.cells.map((cell, cIdx) =>
                cIdx === cellIdx
                  ? {
                      ...cell,
                      content: text
                        ? [{ type: "text" as const, text, marks: [] }]
                        : [],
                    }
                  : cell,
              ),
            }
          : row,
      ),
    }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function addTableRow(block: Block) {
    if (block.type !== "table") return
    const cols = block.rows[0]?.cells.length ?? 1
    const next: Block = {
      ...block,
      rows: [
        ...block.rows,
        {
          id: crypto.randomUUID(),
          cells: Array.from({ length: cols }, () => ({
            id: crypto.randomUUID(),
            content: [],
            header: false,
          })),
        },
      ],
    }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function addTableColumn(block: Block) {
    if (block.type !== "table") return
    const cols = block.rows[0]?.cells.length ?? 1
    const newCount = cols + 1
    const evenWidth = 100 / newCount
    const next: Block = {
      ...block,
      columnWidths: Array.from({ length: newCount }, () => evenWidth),
      rows: block.rows.map((row, rowIdx) => ({
        ...row,
        cells: [
          ...row.cells,
          {
            id: crypto.randomUUID(),
            content: [],
            header: rowIdx === 0,
          },
        ],
      })),
    }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function removeTableRow(block: Block, rowIdx: number) {
    if (block.type !== "table") return
    const next: Block = {
      ...block,
      rows: block.rows.filter((_, i) => i !== rowIdx),
    }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function removeTableColumn(block: Block, colIdx: number) {
    if (block.type !== "table") return
    const widths = block.columnWidths ?? []
    const newWidths = widths.filter((_, i) => i !== colIdx)
    const total = newWidths.reduce((s, w) => s + w, 0)
    const normalized =
      total > 0 ? newWidths.map((w) => (w / total) * 100) : []
    const next: Block = {
      ...block,
      columnWidths: normalized.length > 0 ? normalized : undefined,
      rows: block.rows.map((row) => ({
        ...row,
        cells: row.cells.filter((_, i) => i !== colIdx),
      })),
    }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  function resizeTableColumn(block: Block, newWidths: number[]) {
    if (block.type !== "table") return
    const next: Block = { ...block, columnWidths: newWidths }
    commit(
      blocks.map((item) => (item.id === block.id ? next : item)),
      { type: "update", before: block, block: next },
    )
  }

  // --- Markdown mode -------------------------------------------------------

  function enterMarkdownMode() {
    setMarkdownDraft(serializeBlocksToMarkdown(blocksRef.current))
    setMode("markdown")
    setFocusedBlockId(null)
    clearSelection()
  }

  function applyMarkdown() {
    const next = parseMarkdownToBlocks(markdownDraft)
    blocksRef.current = next
    lastSyncedRef.current = next
    setBlocksRaw(next)
    onChangeRef.current(next)
    onOperationRef.current?.({ type: "markdown", blocks: next }, next)
    setMode("blocks")
  }

  // --- Selection -----------------------------------------------------------

  function clearSelection() {
    if (selectedBlockIdsRef.current.size > 0) {
      setSelectedBlockIds(new Set())
      lastSelectedIndexRef.current = null
      selectionHeadRef.current = null
    }
  }

  function handleGripClick(
    event: ReactMouseEvent,
    blockId: string,
    index: number,
  ) {
    setFocusedBlockId(null)
    if (event.shiftKey && lastSelectedIndexRef.current !== null) {
      const anchor = lastSelectedIndexRef.current
      const from = Math.min(anchor, index)
      const to = Math.max(anchor, index)
      const rangeIds = blocksRef.current.slice(from, to + 1).map((b) => b.id)
      setSelectedBlockIds(new Set(rangeIds))
      selectionHeadRef.current = index
    } else if (event.metaKey || event.ctrlKey) {
      setSelectedBlockIds((prev) => {
        const next = new Set(prev)
        if (next.has(blockId)) next.delete(blockId)
        else next.add(blockId)
        return next
      })
      lastSelectedIndexRef.current = index
      selectionHeadRef.current = index
    } else {
      setSelectedBlockIds(new Set([blockId]))
      lastSelectedIndexRef.current = index
      selectionHeadRef.current = index
    }
  }

  function startMarquee(event: ReactMouseEvent<HTMLDivElement>) {
    if (event.button !== 0) return
    if (event.altKey) return
    const target = event.target as HTMLElement | null
    if (!target) return
    if (
      target.closest(
        "textarea, input, button, [role='button'], [role='menuitem'], [contenteditable='true'], .s2be-popover, .s2be-col-resize",
      )
    ) {
      return
    }
    const startX = event.clientX
    const startY = event.clientY
    const additive = event.shiftKey || event.metaKey || event.ctrlKey
    const baseSelection = additive
      ? new Set(selectedBlockIdsRef.current)
      : new Set<string>()

    if (document.activeElement instanceof HTMLElement) {
      document.activeElement.blur()
    }

    let moved = false

    function update(currentX: number, currentY: number) {
      const left = Math.min(startX, currentX)
      const right = Math.max(startX, currentX)
      const top = Math.min(startY, currentY)
      const bottom = Math.max(startY, currentY)

      const blocksNow = blocksRef.current
      const container = containerRef.current
      if (!container) return

      const intersected: number[] = []
      const elements = container.querySelectorAll("[data-block-id]")
      elements.forEach((el) => {
        const r = el.getBoundingClientRect()
        if (
          r.right >= left &&
          r.left <= right &&
          r.bottom >= top &&
          r.top <= bottom
        ) {
          const id = (el as HTMLElement).dataset.blockId
          if (!id) return
          const idx = blocksNow.findIndex((b) => b.id === id)
          if (idx >= 0) intersected.push(idx)
        }
      })
      intersected.sort((a, b) => a - b)

      const hitIds = intersected.map((i) => blocksNow[i].id)
      const next = new Set(baseSelection)
      for (const id of hitIds) next.add(id)
      setSelectedBlockIds(next)

      if (intersected.length > 0) {
        const startedDownward = currentY >= startY
        const minIdx = intersected[0]
        const maxIdx = intersected[intersected.length - 1]
        lastSelectedIndexRef.current = startedDownward ? minIdx : maxIdx
        selectionHeadRef.current = startedDownward ? maxIdx : minIdx
      }
    }

    function onMove(e: MouseEvent) {
      if (
        !moved &&
        Math.abs(e.clientX - startX) < 3 &&
        Math.abs(e.clientY - startY) < 3
      ) {
        return
      }
      moved = true
      setMarquee({
        startX,
        startY,
        currentX: e.clientX,
        currentY: e.clientY,
      })
      update(e.clientX, e.clientY)
    }

    function onUp() {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      setMarquee(null)
      if (!moved && !additive) {
        setSelectedBlockIds(new Set())
        lastSelectedIndexRef.current = null
        selectionHeadRef.current = null
      }
    }

    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
  }

  // --- Per-block keyboard handling -----------------------------------------

  function handleKeyDown(
    event: KeyboardEvent<HTMLTextAreaElement | HTMLInputElement>,
    block: Block,
    index: number,
  ) {
    const slashQuery = getSlashQuery(block)
    const visible = slashQuery !== null ? filterSlashCommands(slashQuery) : []
    if (
      slashQuery !== null &&
      block.id === focusedBlockId &&
      visible.length > 0
    ) {
      if (event.key === "ArrowDown") {
        event.preventDefault()
        setSlashIndex((c) => (c + 1) % visible.length)
        return
      }
      if (event.key === "ArrowUp") {
        event.preventDefault()
        setSlashIndex((c) => (c - 1 + visible.length) % visible.length)
        return
      }
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault()
        applySlashCommand(block, slashIndex)
        return
      }
      if (event.key === "Escape") {
        event.preventDefault()
        updateText(block, "")
        return
      }
    }

    // Enter — insert/replace based on block type. Code + table own their Enter.
    if (
      event.key === "Enter" &&
      block.type !== "code" &&
      block.type !== "table"
    ) {
      if (event.shiftKey) return
      event.preventDefault()
      const behavior = getEnterBehavior(block)
      if (behavior.action === "replace") {
        const fresh = makeBlock(behavior.type)
        const next: Block = { ...fresh, id: block.id }
        commit(
          blocks.map((item) => (item.id === block.id ? next : item)),
          { type: "replace", before: block, block: next },
          next.id,
        )
      } else {
        insertBlock(block.id, behavior.type)
      }
      return
    }

    // Backspace on an empty block removes it.
    if (
      event.key === "Backspace" &&
      isBlockEmpty(block) &&
      block.type !== "divider"
    ) {
      event.preventDefault()
      deleteBlock(block)
      return
    }
    if (event.key === "Backspace" && block.type === "divider") {
      event.preventDefault()
      deleteBlock(block)
      return
    }

    // Arrow up/down jumps between blocks when at boundary (empty block today).
    if (
      event.key === "ArrowUp" &&
      index > 0 &&
      isBlockEmpty(block)
    ) {
      const prev = blocks[index - 1]
      if (!prev) return
      event.preventDefault()
      shouldAutofocusRef.current = true
      setFocusedBlockId(prev.id)
    }
    if (
      event.key === "ArrowDown" &&
      index < blocks.length - 1 &&
      isBlockEmpty(block)
    ) {
      const next = blocks[index + 1]
      if (!next) return
      event.preventDefault()
      shouldAutofocusRef.current = true
      setFocusedBlockId(next.id)
    }
  }

  // Auto-focus after block operations
  useEffect(() => {
    if (!shouldAutofocusRef.current || !focusedBlockId) return
    const target = inputRefs.current[focusedBlockId]
    if (!target) return
    target.focus()
    if ("setSelectionRange" in target && typeof target.value === "string") {
      const pos = target.value.length
      target.setSelectionRange(pos, pos)
    }
    shouldAutofocusRef.current = false
  }, [focusedBlockId])

  // Global keyboard handler — Cmd+A, Shift+Arrow on selection, delete on
  // selection, Escape to clear selection.
  const deleteBlocksRef = useRef(deleteBlocks)
  deleteBlocksRef.current = deleteBlocks
  useEffect(() => {
    function onKeyDown(event: globalThis.KeyboardEvent) {
      const target = event.target as HTMLElement | null
      const isEditableTarget =
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement ||
        target?.isContentEditable === true

      if (
        (event.metaKey || event.ctrlKey) &&
        event.key === "a" &&
        !isEditableTarget &&
        containerRef.current?.contains(target)
      ) {
        event.preventDefault()
        const all = blocksRef.current.map((b) => b.id)
        setSelectedBlockIds(new Set(all))
        lastSelectedIndexRef.current = 0
        selectionHeadRef.current = all.length - 1
        return
      }

      const selected = selectedBlockIdsRef.current

      if (
        event.shiftKey &&
        (event.key === "ArrowUp" || event.key === "ArrowDown") &&
        !isEditableTarget &&
        selected.size > 0
      ) {
        const blocksNow = blocksRef.current
        if (blocksNow.length === 0) return

        let anchor = lastSelectedIndexRef.current
        let head = selectionHeadRef.current
        if (anchor === null || head === null) {
          const indices = blocksNow
            .map((b, i) => (selected.has(b.id) ? i : -1))
            .filter((i) => i >= 0)
          if (indices.length === 0) return
          anchor = anchor ?? indices[0]
          head = head ?? indices[indices.length - 1]
        }

        event.preventDefault()
        const delta = event.key === "ArrowDown" ? 1 : -1
        const newHead = Math.max(
          0,
          Math.min(blocksNow.length - 1, head + delta),
        )
        lastSelectedIndexRef.current = anchor
        selectionHeadRef.current = newHead
        const from = Math.min(anchor, newHead)
        const to = Math.max(anchor, newHead)
        const ids = blocksNow.slice(from, to + 1).map((b) => b.id)
        setSelectedBlockIds(new Set(ids))
        return
      }

      if (selected.size === 0) return

      if (event.key === "Escape") {
        event.preventDefault()
        setSelectedBlockIds(new Set())
        lastSelectedIndexRef.current = null
        selectionHeadRef.current = null
        return
      }

      if (
        (event.key === "Backspace" || event.key === "Delete") &&
        !isEditableTarget
      ) {
        event.preventDefault()
        deleteBlocksRef.current(Array.from(selected))
      }
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [])

  // biome-ignore lint/correctness/useExhaustiveDependencies: scrollHeight depends on the draft text
  useEffect(() => {
    if (mode !== "markdown") return
    const node = markdownRef.current
    if (!node) return
    node.style.height = "0px"
    node.style.height = `${node.scrollHeight}px`
  }, [mode, markdownDraft])

  useEffect(() => {
    if (mode !== "markdown") return
    markdownRef.current?.focus()
  }, [mode])

  // --- Render ---------------------------------------------------------------

  const sectionClassName = ["s2be", compact ? "s2be--compact" : "", className]
    .filter(Boolean)
    .join(" ")

  if (mode === "markdown") {
    return (
      <section className={sectionClassName} style={style}>
        <div className="s2be-toolbar">
          <button type="button" onClick={applyMarkdown}>
            <BlocksIcon className="s2be-icon-sm" />
            Done
          </button>
          <button type="button" onClick={() => setMode("blocks")}>
            Cancel
          </button>
        </div>
        <textarea
          ref={markdownRef}
          className="s2be-markdown"
          value={markdownDraft}
          onChange={(event) => setMarkdownDraft(event.target.value)}
          spellCheck={false}
        />
      </section>
    )
  }

  return (
    <section className={sectionClassName} style={style}>
      <div className="s2be-toolbar">
        <button
          type="button"
          onClick={() => insertBlock(blocks.at(-1)?.id ?? "")}
        >
          <PlusIcon className="s2be-icon-sm" />
          Block
        </button>
        <button type="button" onClick={enterMarkdownMode}>
          <MarkdownIcon className="s2be-icon-sm" />
          Markdown
        </button>
      </div>
      {/* biome-ignore lint/a11y/noStaticElementInteractions: marquee + drop target */}
      <div
        ref={containerRef}
        className="s2be-document"
        onMouseDown={startMarquee}
        onDragOver={(event) => {
          if (!draggedBlockId || !containerRef.current) return
          event.preventDefault()
          const els = Array.from(
            containerRef.current.querySelectorAll("[data-block-id]"),
          ) as HTMLElement[]
          const y = event.clientY
          let idx = els.length
          for (let i = 0; i < els.length; i++) {
            const rect = els[i].getBoundingClientRect()
            if (y < rect.top + rect.height / 2) {
              idx = i
              break
            }
          }
          const isMulti =
            selectedBlockIds.has(draggedBlockId) && selectedBlockIds.size > 1
          if (isMulti) {
            const above = idx > 0 ? blocks[idx - 1] : null
            const below = idx < blocks.length ? blocks[idx] : null
            const aboveSelected = above ? selectedBlockIds.has(above.id) : false
            const belowSelected = below ? selectedBlockIds.has(below.id) : false
            if (
              (aboveSelected && belowSelected) ||
              (aboveSelected && !below) ||
              (!above && belowSelected)
            ) {
              setDropIndex(null)
            } else {
              setDropIndex(idx)
            }
          } else {
            const srcIdx = blocks.findIndex((b) => b.id === draggedBlockId)
            if (idx === srcIdx || idx === srcIdx + 1) setDropIndex(null)
            else setDropIndex(idx)
          }
        }}
        onDrop={(event) => {
          event.preventDefault()
          if (draggedBlockId && dropIndex !== null) {
            const ids =
              selectedBlockIds.has(draggedBlockId) && selectedBlockIds.size > 1
                ? Array.from(selectedBlockIds)
                : [draggedBlockId]
            moveBlocksToIndex(ids, dropIndex)
          }
          setDraggedBlockId(null)
          setDropIndex(null)
        }}
        onDragEnd={() => {
          setDraggedBlockId(null)
          setDropIndex(null)
        }}
        onDragLeave={(event) => {
          if (!containerRef.current?.contains(event.relatedTarget as Node)) {
            setDropIndex(null)
          }
        }}
      >
        {blocks.map((block, index) => (
          <BlockRow
            key={block.id}
            block={block}
            blocks={blocks}
            index={index}
            placeholder={placeholder}
            autoFocus={autoFocus && index === 0}
            focused={focusedBlockId === block.id}
            isSelected={selectedBlockIds.has(block.id)}
            isMultiSelectionDrag={
              draggedBlockId !== null &&
              selectedBlockIds.has(draggedBlockId) &&
              selectedBlockIds.size > 1
            }
            isDragging={
              draggedBlockId === block.id ||
              (draggedBlockId !== null &&
                selectedBlockIds.has(draggedBlockId) &&
                selectedBlockIds.size > 1 &&
                selectedBlockIds.has(block.id))
            }
            showDropAbove={dropIndex === index && draggedBlockId !== null}
            slashIndex={slashIndex}
            menuOpen={openMenuBlockId === block.id}
            onMenuOpenChange={(next) => {
              if (
                next &&
                (gripPressedRef.current || isDraggingRef.current)
              ) {
                return
              }
              setOpenMenuBlockId(next ? block.id : null)
            }}
            inputRef={(node) => {
              inputRefs.current[block.id] = node
            }}
            onFocusBlock={() => {
              clearSelection()
              setFocusedBlockId(block.id)
            }}
            onUpdateText={(text) => updateText(block, text)}
            onSlashApply={(commandIndex) =>
              applySlashCommand(block, commandIndex)
            }
            onKeyDown={(event) => handleKeyDown(event, block, index)}
            onMove={(direction) => moveBlock(block, direction)}
            onReplace={(type) => replaceType(block, type)}
            onDelete={() => deleteBlock(block)}
            onToggleTodo={() => toggleTodo(block)}
            onSetCalloutColor={(color) => setCalloutColor(block, color)}
            onCodeLanguage={(language) => setCodeLanguage(block, language)}
            onTableUpdateCell={(rowIdx, cellIdx, text) =>
              updateTableCell(block, rowIdx, cellIdx, text)
            }
            onTableAddRow={() => addTableRow(block)}
            onTableAddColumn={() => addTableColumn(block)}
            onTableRemoveRow={(rowIdx) => removeTableRow(block, rowIdx)}
            onTableRemoveColumn={(colIdx) => removeTableColumn(block, colIdx)}
            onTableResize={(widths) => resizeTableColumn(block, widths)}
            onGripClick={(event) => handleGripClick(event, block.id, index)}
            onGripPointerDown={() => {
              gripPressedRef.current = true
            }}
            onGripPointerUp={() => {
              gripPressedRef.current = false
            }}
            onDragStartBlock={(event) => {
              isDraggingRef.current = true
              setOpenMenuBlockId(null)
              if (
                selectedBlockIdsRef.current.has(block.id) &&
                selectedBlockIdsRef.current.size > 1
              ) {
                // keep selection — drop handler moves all selected blocks
              } else {
                setSelectedBlockIds(new Set([block.id]))
                lastSelectedIndexRef.current = index
              }
              setDraggedBlockId(block.id)
              event.dataTransfer.effectAllowed = "move"
              event.dataTransfer.setData("text/plain", block.id)
            }}
            onDragEndBlock={() => {
              isDraggingRef.current = false
              gripPressedRef.current = false
              setDraggedBlockId(null)
              setDropIndex(null)
            }}
          />
        ))}

        {dropIndex === blocks.length && draggedBlockId ? (
          <div className="s2be-drop-indicator s2be-drop-indicator--end" />
        ) : null}
      </div>

      {marquee ? (
        <div
          className="s2be-marquee"
          style={{
            left: Math.min(marquee.startX, marquee.currentX),
            top: Math.min(marquee.startY, marquee.currentY),
            width: Math.abs(marquee.currentX - marquee.startX),
            height: Math.abs(marquee.currentY - marquee.startY),
          }}
        />
      ) : null}
    </section>
  )
}

// ---------------------------------------------------------------------------
// BlockRow — one block in the document.
// ---------------------------------------------------------------------------

interface BlockRowProps {
  block: Block
  blocks: Block[]
  index: number
  placeholder: string
  autoFocus: boolean
  focused: boolean
  isSelected: boolean
  isMultiSelectionDrag: boolean
  isDragging: boolean
  showDropAbove: boolean
  slashIndex: number
  menuOpen: boolean
  onMenuOpenChange: (open: boolean) => void
  inputRef: (node: EditableRef) => void
  onFocusBlock: () => void
  onUpdateText: (text: string) => void
  onSlashApply: (commandIndex: number) => void
  onKeyDown: (event: KeyboardEvent<HTMLTextAreaElement | HTMLInputElement>) => void
  onMove: (direction: -1 | 1) => void
  onReplace: (type: SimpleBlockType) => void
  onDelete: () => void
  onToggleTodo: () => void
  onSetCalloutColor: (color: string | undefined) => void
  onCodeLanguage: (language: string) => void
  onTableUpdateCell: (rowIdx: number, cellIdx: number, text: string) => void
  onTableAddRow: () => void
  onTableAddColumn: () => void
  onTableRemoveRow: (rowIdx: number) => void
  onTableRemoveColumn: (colIdx: number) => void
  onTableResize: (widths: number[]) => void
  onGripClick: (event: ReactMouseEvent) => void
  onGripPointerDown: () => void
  onGripPointerUp: () => void
  onDragStartBlock: (event: React.DragEvent<HTMLButtonElement>) => void
  onDragEndBlock: () => void
}

function BlockRow(props: BlockRowProps) {
  const {
    block,
    blocks,
    index,
    placeholder,
    autoFocus,
    focused,
    isSelected,
    isDragging,
    showDropAbove,
    slashIndex,
    menuOpen,
    onMenuOpenChange,
    inputRef,
    onFocusBlock,
    onUpdateText,
    onSlashApply,
    onKeyDown,
    onMove,
    onReplace,
    onDelete,
    onToggleTodo,
    onSetCalloutColor,
    onCodeLanguage,
    onTableUpdateCell,
    onTableAddRow,
    onTableAddColumn,
    onTableRemoveRow,
    onTableRemoveColumn,
    onTableResize,
    onGripClick,
    onGripPointerDown,
    onGripPointerUp,
    onDragStartBlock,
    onDragEndBlock,
  } = props

  const simpleType = toSimpleType(block)
  const text = getBlockText(block)
  const prefix = getListPrefix(block, blocks, index)
  const slashQuery = focused ? getSlashQuery(block) : null
  const visibleCommands = useMemo(
    () => filterSlashCommands(slashQuery),
    [slashQuery],
  )
  const isTodo = block.type === "list" && block.style === "todo"
  const isChecked = isTodo && (block.items[0]?.checked ?? false)

  const calloutOverride =
    block.type === "callout" && block.color
      ? calloutColorStyle(block.color)
      : null

  const convertibleTypes = getConvertibleTypes(simpleType)
  const blockClassName = [
    "s2be-block",
    isDragging ? "s2be-block--dragging" : "",
    isSelected && !isDragging ? "s2be-block--selected" : "",
    focused ? "s2be-block--focused" : "",
  ]
    .filter(Boolean)
    .join(" ")

  return (
    <article
      className={blockClassName}
      data-block-id={block.id}
      data-type={simpleType}
      style={calloutOverride?.style}
    >
      {showDropAbove ? (
        <div className="s2be-drop-indicator s2be-drop-indicator--top" />
      ) : null}

      <div className="s2be-grip">
        <button
          type="button"
          className="s2be-grip-handle"
          aria-label="Block options"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          draggable
          onPointerDown={onGripPointerDown}
          onPointerUp={onGripPointerUp}
          onPointerCancel={onGripPointerUp}
          onDragStart={onDragStartBlock}
          onDragEnd={onDragEndBlock}
          onMouseDownCapture={(event) => {
            if (event.shiftKey || event.metaKey || event.ctrlKey) {
              event.preventDefault()
              event.stopPropagation()
              onGripClick(event)
              return
            }
            onGripClick(event)
          }}
          onClick={() => onMenuOpenChange(!menuOpen)}
        >
          <GripIcon className="s2be-icon-sm" />
        </button>
        <Popover open={menuOpen} onClose={() => onMenuOpenChange(false)}>
          <div className="s2be-popover-label">Move</div>
          <button
            type="button"
            role="menuitem"
            className="s2be-popover-item"
            disabled={index === 0}
            onClick={() => {
              onMove(-1)
              onMenuOpenChange(false)
            }}
          >
            <ArrowUpIcon className="s2be-icon-sm" />
            Move up
          </button>
          <button
            type="button"
            role="menuitem"
            className="s2be-popover-item"
            disabled={index === blocks.length - 1}
            onClick={() => {
              onMove(1)
              onMenuOpenChange(false)
            }}
          >
            <ArrowDownIcon className="s2be-icon-sm" />
            Move down
          </button>
          {convertibleTypes.length > 0 ? (
            <>
              <div className="s2be-popover-separator" />
              <div className="s2be-popover-label">Replace with</div>
              {SLASH_COMMANDS.filter(
                (cmd) =>
                  cmd.id !== simpleType && convertibleTypes.includes(cmd.id),
              ).map((cmd) => {
                const ItemIcon = SLASH_COMMAND_ICONS[cmd.id]
                return (
                  <button
                    key={cmd.id}
                    type="button"
                    role="menuitem"
                    className="s2be-popover-item"
                    onClick={() => {
                      onReplace(cmd.id)
                      onMenuOpenChange(false)
                    }}
                  >
                    <ItemIcon className="s2be-icon-sm" />
                    {cmd.title}
                  </button>
                )
              })}
            </>
          ) : null}
          <div className="s2be-popover-separator" />
          <button
            type="button"
            role="menuitem"
            className="s2be-popover-item s2be-popover-item--danger"
            onClick={() => {
              onDelete()
              onMenuOpenChange(false)
            }}
          >
            <TrashIcon className="s2be-icon-sm" />
            Delete
          </button>
        </Popover>
      </div>

      <div className="s2be-block-content">
        {isTodo ? (
          <button
            type="button"
            className={[
              "s2be-todo",
              isChecked ? "s2be-todo--checked" : "",
            ].join(" ")}
            onClick={onToggleTodo}
            aria-pressed={isChecked}
            aria-label="Toggle todo"
          >
            {isChecked ? <CheckIcon className="s2be-icon-sm" /> : null}
          </button>
        ) : prefix !== null ? (
          <span className="s2be-prefix">{prefix}</span>
        ) : null}

        {block.type === "callout" ? (
          <CalloutColorPicker
            value={block.color}
            onChange={onSetCalloutColor}
          />
        ) : null}

        {block.type === "divider" ? (
          <button
            type="button"
            className="s2be-divider-button"
            onFocus={onFocusBlock}
            onKeyDown={(event) => {
              if (event.key === "Backspace") {
                event.preventDefault()
                onDelete()
              }
            }}
            aria-label="Divider"
          >
            <span className="s2be-divider" />
          </button>
        ) : block.type === "table" ? (
          <TableBlockView
            block={block}
            inputRef={(node) => inputRef(node)}
            onFocus={onFocusBlock}
            onKeyDown={onKeyDown}
            onUpdateCell={onTableUpdateCell}
            onAddRow={onTableAddRow}
            onAddColumn={onTableAddColumn}
            onRemoveRow={onTableRemoveRow}
            onRemoveColumn={onTableRemoveColumn}
            onResize={onTableResize}
          />
        ) : block.type === "code" ? (
          <CodeBlockView
            block={block}
            text={text}
            placeholder={getPlaceholder(simpleType, "")}
            autoFocus={autoFocus}
            inputRef={(node) => inputRef(node)}
            onFocus={onFocusBlock}
            onKeyDown={onKeyDown}
            onChangeText={onUpdateText}
            onChangeLanguage={onCodeLanguage}
          />
        ) : (
          <AutoGrowTextarea
            value={text}
            placeholder={
              index === 0
                ? getPlaceholder(simpleType, placeholder)
                : getPlaceholder(simpleType, "")
            }
            autoFocus={autoFocus}
            className="s2be-input"
            inputRef={(node) => inputRef(node)}
            onFocus={onFocusBlock}
            onKeyDown={onKeyDown}
            onChange={onUpdateText}
          />
        )}

        {focused && visibleCommands.length > 0 ? (
          <div className="s2be-slash-menu" role="listbox">
            {visibleCommands.map((cmd, i) => {
              const ItemIcon = SLASH_COMMAND_ICONS[cmd.id]
              const highlighted = i === slashIndex
              return (
                <button
                  key={cmd.id}
                  type="button"
                  role="option"
                  aria-selected={highlighted}
                  className={[
                    "s2be-slash-item",
                    highlighted ? "s2be-slash-item--active" : "",
                  ].join(" ")}
                  onMouseDown={(event) => {
                    event.preventDefault()
                    onSlashApply(i)
                  }}
                >
                  <ItemIcon className="s2be-icon-sm" />
                  <span className="s2be-slash-text">
                    <strong>{cmd.title}</strong>
                    <em>{cmd.description}</em>
                  </span>
                </button>
              )
            })}
          </div>
        ) : null}
      </div>
    </article>
  )
}
