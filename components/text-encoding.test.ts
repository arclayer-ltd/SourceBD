// Text that was saved as UTF-8, read back as Windows-1252 and saved again reaches the buyer
// as "Saving" followed by three wrong characters instead of "…" (issue 638). This fails if
// that garbling is in any source or text file under components/ or app/.

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { it } from "node:test";

const TEXT = /\.(tsx?|jsx?|mjs|cjs|css|mdx?|json|svg|html|txt)$/;

// A UTF-8 lead byte (C2, C3 or E2: Latin-1 letters and signs, general punctuation) shown as
// Windows-1252 is Â, Ã or â; the byte after it, a continuation byte (80 to BF), is one of these.
const continuation = new TextDecoder("windows-1252").decode(Uint8Array.from({ length: 64 }, (_, i) => 0x80 + i));
const garbled = new RegExp(`[ÂÃâ][${continuation.replace(/[\]\\^-]/g, "\\$&")}]`, "u");

function* files(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* files(full);
    else if (TEXT.test(entry.name)) yield full;
  }
}

it("the detector knows the garbling from issue 638 and leaves good text alone", () => {
  // Written as escapes so this file passes its own check: "Saving…", "10 · Results", "the ×", "C’s", "café" garbled.
  for (const bad of ["Saving\u00e2\u20ac\u00a6", "10 \u00c2\u00b7 Results", "the \u00c3\u2014 that clears", "C\u00e2\u20ac\u2122s", "caf\u00c3\u00a9"]) assert.match(bad, garbled, bad);
  for (const good of ["Saving…", "10 · Results", "the × that clears", "C’s", "café", "Dhākā — “quoted”"]) assert.doesNotMatch(good, garbled, good);
});

it("no file under components/ or app/ holds UTF-8 garbled through Windows-1252", () => {
  const found: string[] = [];
  for (const root of ["components", "app"]) {
    for (const file of files(path.join(process.cwd(), root))) {
      readFileSync(file, "utf8").split("\n").forEach((line, i) => {
        const m = garbled.exec(line);
        if (m) found.push(`${path.relative(process.cwd(), file)}:${i + 1}: "${m[0]}"`);
      });
    }
  }
  assert.deepEqual(found, [], "Retype these characters as the real ones (…, ·, ×, ’):");
});
