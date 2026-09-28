import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { ImageBlock, type Block } from "./schema.js";

export interface UploadedImage {
  /** Persisted asset identifier; it need not be a public URL. */
  src: string;
  alt?: string;
  width?: number;
  height?: number;
}

export interface ImageUploadOptions {
  /** Client hints only. The host must validate bytes, size and ownership. */
  mimeTypes: readonly string[];
  maxBytes: number;
  upload: (
    file: File,
    options: { signal: AbortSignal },
  ) => Promise<UploadedImage>;
}

export type ResolveImageSource = (source: string) => string | null | undefined;

export function displayImageSource(
  source: string,
  resolve?: ResolveImageSource,
): string | null {
  if (!resolve) return null;
  try {
    const url = resolve(source);
    // biome-ignore lint/suspicious/noControlCharactersInRegex: URL parsing strips these characters and could disguise a protocol-relative address.
    if (!url || /[\u0000-\u001f\u007f]/.test(url)) return null;
    if (url.startsWith("/") && !url.startsWith("//") && !url.includes("\\"))
      return url;
    const parsed = new URL(url);
    return ["https:", "http:", "blob:"].includes(parsed.protocol)
      ? parsed.href
      : null;
  } catch {
    return null;
  }
}

export function ImageUploadControl({
  options,
  label,
  disabled = false,
  onUploaded,
}: {
  options: ImageUploadOptions;
  label: string;
  disabled?: boolean;
  onUploaded: (image: UploadedImage) => boolean;
}) {
  const fileInput = useRef<HTMLInputElement>(null);
  const active = useRef<AbortController | null>(null);
  const selected = useRef<File | null>(null);
  const uploaded = useRef<UploadedImage | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  useEffect(
    () => () => {
      active.current?.abort();
      active.current = null;
    },
    [],
  );

  async function upload(file: File) {
    if (active.current) return;
    selected.current = file;
    if (
      !Number.isFinite(options.maxBytes) ||
      options.maxBytes <= 0 ||
      file.size === 0 ||
      file.size > options.maxBytes
    ) {
      selected.current = null;
      setError(
        `Choose a nonempty image no larger than ${options.maxBytes} bytes.`,
      );
      return;
    }
    if (!options.mimeTypes.includes(file.type)) {
      selected.current = null;
      setError("This image type is not supported.");
      return;
    }
    const controller = new AbortController();
    active.current = controller;
    setPending(true);
    setError("");
    try {
      const result =
        uploaded.current ??
        (await options.upload(file, { signal: controller.signal }));
      if (active.current !== controller || controller.signal.aborted) return;
      // Validate host output before allowing it into the document. Strip any
      // extra response fields instead of persisting service metadata/secrets.
      const parsed = ImageBlock.parse({
        ...result,
        id: "uploaded",
        type: "image",
        caption: [],
      });
      const image: UploadedImage = {
        src: parsed.src,
        alt: result.alt === undefined ? undefined : parsed.alt,
        width: parsed.width,
        height: parsed.height,
      };
      uploaded.current = image;
      if (!onUploaded(image)) {
        setError(
          "The image was uploaded but could not be added here. Retry after making space in the document.",
        );
        return;
      }
      selected.current = null;
      uploaded.current = null;
    } catch {
      if (active.current === controller && !controller.signal.aborted)
        setError("Image upload failed. Try again.");
    } finally {
      if (active.current === controller) {
        active.current = null;
        setPending(false);
      }
    }
  }

  return (
    <span className="s2be-image-upload" aria-busy={pending}>
      <input
        ref={fileInput}
        type="file"
        accept={options.mimeTypes.join(",")}
        aria-label={label}
        hidden
        onChange={(event) => {
          const file = event.currentTarget.files?.[0];
          event.currentTarget.value = "";
          if (file) {
            uploaded.current = null;
            void upload(file);
          }
        }}
      />
      <button
        type="button"
        disabled={disabled || pending}
        onClick={() => fileInput.current?.click()}
      >
        {label}
      </button>
      {pending && (
        <>
          <span role="status">Uploading image…</span>
          <button
            type="button"
            onClick={() => {
              active.current?.abort();
              active.current = null;
              selected.current = null;
              uploaded.current = null;
              setPending(false);
              setError("");
            }}
          >
            Cancel upload
          </button>
        </>
      )}
      {error && (
        <>
          <span role="alert">{error}</span>
          {selected.current && (
            <button
              type="button"
              disabled={disabled || pending}
              onClick={() => {
                if (selected.current) void upload(selected.current);
              }}
            >
              Retry image
            </button>
          )}
        </>
      )}
    </span>
  );
}

export function ImageBlockView({
  block,
  resolve,
  upload,
  inputRef,
  onFocus,
  onKeyDown,
  onAlt,
  onReplace,
}: {
  block: Extract<Block, { type: "image" }>;
  resolve?: ResolveImageSource;
  upload?: ImageUploadOptions;
  inputRef: (node: HTMLInputElement | null) => void;
  onFocus: () => void;
  onKeyDown: (event: KeyboardEvent<HTMLElement>) => void;
  onAlt: (alt: string) => void;
  onReplace: (image: UploadedImage) => boolean;
}) {
  const source = displayImageSource(block.src, resolve);
  const [failedSource, setFailedSource] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const failed = source !== null && failedSource === source;
  return (
    <figure className="s2be-image">
      {source && !failed ? (
        <img
          key={`${source}:${attempt}`}
          src={source}
          alt={block.alt}
          width={block.width}
          height={block.height}
          referrerPolicy="no-referrer"
          onError={() => setFailedSource(source)}
        />
      ) : (
        <div className="s2be-image-placeholder" role="status">
          {failed
            ? "Image could not be loaded."
            : "Image preview is unavailable."}
        </div>
      )}
      {failed && (
        <button
          type="button"
          onClick={() => {
            setFailedSource(null);
            setAttempt((value) => value + 1);
          }}
        >
          Retry preview
        </button>
      )}
      <label>
        Image description (alt text)
        <input
          ref={inputRef}
          value={block.alt}
          onFocus={onFocus}
          onKeyDown={onKeyDown}
          onChange={(event) => onAlt(event.target.value)}
        />
      </label>
      {upload && (
        <ImageUploadControl
          key={block.src}
          options={upload}
          label="Replace image"
          onUploaded={onReplace}
        />
      )}
    </figure>
  );
}
