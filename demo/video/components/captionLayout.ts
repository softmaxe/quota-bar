/**
 * Pure text layout for handwritten Captions: how a Caption is split into write
 * units and where its lines may break. No React or Remotion imports, so it can
 * be unit-tested.
 */

/** CJK punctuation that must not start a line / must not end a line. */
const NO_LINE_START = "，。、；：？！”’）》」』…—,.;:?!)";
const NO_LINE_END = "“‘（《「『(";
/** Punctuation that ends a clause: the natural places for a line break. */
const CLAUSE_END = "，。、；：？！…,.;:?!";

/**
 * Splits text into write units, which are also the only places a line may
 * break: runs of Latin letters/digits stay together, a short quoted phrase
 * (e.g. “刷题”) stays whole, a reduplicated hanzi pair (e.g. 看看) is not split,
 * other chars are single, and punctuation is glued
 * to its neighbour so it never starts or ends a line.
 */
export function tokenize(text: string): string[] {
  const raw = text.match(/“[^“”]{1,6}”|[A-Za-z0-9]+|\s+|(\p{Script=Han})\1|./gu) ?? [];
  const tokens: string[] = [];
  let pendingOpen = "";
  for (const t of raw) {
    if (NO_LINE_END.includes(t)) {
      pendingOpen += t;
    } else if (NO_LINE_START.includes(t) && tokens.length > 0 && !pendingOpen) {
      tokens[tokens.length - 1] += t;
    } else {
      tokens.push(pendingOpen + t);
      pendingOpen = "";
    }
  }
  if (pendingOpen) tokens.push(pendingOpen);
  return tokens;
}

export const isSpace = (t: string) => /^\s+$/.test(t);
export const isLatin = (t: string) => /^[A-Za-z0-9]+$/.test(t);

/** Rough advance width of `text` in em: full-width (CJK) 1, Latin/digits 0.55, spaces 0.3. */
export function emWidth(text: string): number {
  return [...text].reduce((w, ch) => w + (/\s/.test(ch) ? 0.3 : /[\x21-\x7e]/.test(ch) ? 0.55 : 1), 0);
}

/** A run of consecutive write units (by index into the token list). */
export interface Clause {
  tokens: number[];
  /** True if the clause fits on one line and must not be broken inside. */
  keep: boolean;
}

/**
 * Groups write units into clauses, each ending at clause punctuation (，：？ …).
 * A clause that fits on one line is kept whole, so a wrapped Caption breaks at
 * a natural point ("…我们还是想看看：" / "这只鹈鹕，…") instead of mid-phrase;
 * a clause too long for a line may still wrap between its units.
 */
export function clauses(tokens: string[], fontSize: number, width: number): Clause[] {
  const out: Clause[] = [];
  let current: number[] = [];
  const flush = () => {
    if (current.length === 0) return;
    const text = current.map((i) => tokens[i]).join("");
    out.push({ tokens: current, keep: emWidth(text) * fontSize <= width * 0.95 });
    current = [];
  };
  tokens.forEach((token, i) => {
    current.push(i);
    if (CLAUSE_END.includes(token.at(-1) ?? "")) flush();
  });
  flush();
  return out;
}
