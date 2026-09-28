import { expect, test } from "bun:test";
import { displayImageSource } from "./image-react.js";

test("stored asset identifiers never become implicit image requests", () => {
  expect(displayImageSource("https://untrusted.example/image.png")).toBeNull();
  expect(displayImageSource("owned-id", () => null)).toBeNull();
  expect(
    displayImageSource("owned-id", () => {
      throw new Error("Unavailable");
    }),
  ).toBeNull();
});

test("explicit image resolution rejects active or ambiguous URL schemes", () => {
  for (const value of [
    "javascript:alert(1)",
    "data:image/svg+xml,<svg/>",
    "//example.com/image",
    "/\\example.com/image",
    "file:///tmp/image",
    "relative.png",
    "/\n/example.com/image",
  ]) {
    expect(displayImageSource("owned-id", () => value)).toBeNull();
  }
  expect(displayImageSource("owned-id", () => "/api/media/owned-id")).toBe(
    "/api/media/owned-id",
  );
  expect(
    displayImageSource(
      "owned-id",
      () => "https://api.example.com/media/owned-id",
    ),
  ).toBe("https://api.example.com/media/owned-id");
  expect(
    displayImageSource("owned-id", () => "blob:https://example.com/id"),
  ).toBe("blob:https://example.com/id");
});
