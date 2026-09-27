import { interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import type { Caption, Language } from "../../timeline";
import { clamp } from "../anim";
import { HAND_FONT } from "../fonts";
import { PALETTE } from "../theme";
import { clauses, isLatin, isSpace, tokenize } from "./captionLayout";

/** Writing speed in characters per second, and the cap as a share of the Caption's time. */
const CHARS_PER_SECOND = 14;
const MAX_WRITE_SHARE = 0.45;
/** Frames for a single character's ink to go down, and for the Caption to lift off at the end. */
const STROKE_FRAMES = 7;
const EXIT_FRAMES = 9;

interface Props {
  caption: Caption;
  language: Language;
}

/**
 * A Caption "written" onto the paper: each character is revealed left-to-right
 * by a wipe, one after another, then the whole line lifts off before its end.
 * Must be rendered inside a <Sequence> that starts at the Caption's start.
 */
export const HandwrittenCaption: React.FC<Props> = ({ caption, language }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const { placement: p } = caption;
  const durationFrames = Math.round((caption.end - caption.start) * fps);

  const tokens = tokenize(caption.text[language]);
  const weights = tokens.map((t) => (isSpace(t) ? 0 : isLatin(t) ? t.length * 0.55 : [...t].length));
  const totalWeight = weights.reduce((a, b) => a + b, 0) || 1;
  const writeFrames = Math.min((totalWeight / CHARS_PER_SECOND) * fps, durationFrames * MAX_WRITE_SHARE);
  const framesPerWeight = writeFrames / totalWeight;

  const exit = interpolate(frame, [durationFrames - EXIT_FRAMES, durationFrames], [1, 0], clamp);

  const isTitle = caption.variant === "title";
  const left = p.align === "center" ? p.x - p.width / 2 : p.align === "right" ? p.x - p.width : p.x;

  // Each write unit's start frame and ink duration, in reading order.
  let cursor = 0;
  const timing = tokens.map((_, i) => {
    const startFrame = cursor * framesPerWeight;
    cursor += weights[i];
    return { startFrame, strokeFrames: Math.max(STROKE_FRAMES, weights[i] * framesPerWeight * 1.4) };
  });

  const renderToken = (i: number) => {
    const token = tokens[i];
    if (isSpace(token)) return <span key={i} style={{ whiteSpace: "pre" }}>{token}</span>;
    const { startFrame, strokeFrames } = timing[i];
    const reveal = interpolate(frame, [startFrame, startFrame + strokeFrames], [0, 1], clamp);
    return (
      <span
        key={i}
        style={{
          display: "inline-block",
          clipPath: `inset(-20% ${(1 - reveal) * 100}% -20% -5%)`,
          opacity: interpolate(reveal, [0, 0.35], [0, 1], { extrapolateRight: "clamp" }),
          transform: `translateY(${(1 - reveal) * 3}px)`,
        }}
      >
        {token}
      </span>
    );
  };

  return (
    <div
      data-caption-id={caption.id}
      style={{
        position: "absolute",
        left,
        top: p.y,
        width: p.width,
        textAlign: p.align,
        fontFamily: `"${HAND_FONT}", serif`,
        fontSize: p.fontSize,
        lineHeight: 1.35,
        textWrap: "balance",
        color: isTitle ? PALETTE.accent : PALETTE.ink,
        transform: `rotate(${p.rotate ?? 0}deg)`,
        opacity: exit,
        // Slight graphite softness so glyphs sit "in" the paper.
        textShadow: `0 0 1px ${isTitle ? "rgba(194,86,43,0.35)" : "rgba(58,46,42,0.35)"}`,
      }}
    >
      {/* Lines break only between clauses, or inside a clause too long for one line. */}
      {clauses(tokens, p.fontSize, p.width).map((clause, k) => (
        <span key={k} style={clause.keep ? { whiteSpace: "nowrap" } : undefined}>
          {clause.tokens.map(renderToken)}
        </span>
      ))}
    </div>
  );
};
