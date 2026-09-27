import type { Beat, Language } from "../../timeline";
import { ramp, useBeatTime } from "../anim";
import { HAND_FONT } from "../fonts";
import { RoughDrawing } from "../rough/RoughDrawing";
import { PALETTE } from "../theme";

const LABELS = {
  quota: {en: "Quota runs out", zh: "额度用完了"},
  glance: {en: "One glance", zh: "看一眼就知道"},
  reset: {en: "A fresh quota window", zh: "额度重置"},
  cost: {en: "Every dollar", zh: "每一笔开销"},
  outro: {en: "Take the report with you", zh: "带上你的报告"},
};

/** A complete renderable Beat while its story drawings are being implemented. */
export const PlaceholderBeat: React.FC<{beat: Beat; language: Language}> = ({beat, language}) => {
  const {t} = useBeatTime(beat);
  const drawn = ramp(t, beat.start + 0.4, beat.start + 2);
  return (
    <svg width={1920} height={1080}>
      <text x={155} y={185} fontFamily={HAND_FONT} fontSize={30} fill={PALETTE.pencil}>QuotaBar / 0{beat.index}</text>
      <RoughDrawing seed={110 + beat.index} progress={drawn}
        options={{stroke: PALETTE.pencil, strokeWidth: 3, fill: PALETTE.cream, fillStyle: "solid"}}
        build={(g, o) => [g.rectangle(290, 300, 1340, 390, o)]} />
      <text x={960} y={468} textAnchor="middle" fontFamily={HAND_FONT} fontSize={68}
        opacity={drawn} fill={PALETTE.ink}>{LABELS[beat.key][language]}</text>
      <RoughDrawing seed={210 + beat.index} progress={drawn}
        options={{stroke: PALETTE.accent, strokeWidth: 5, roughness: 2}}
        build={(g, o) => [g.line(570, 520, 1350, 526, o)]} />
      <text x={960} y={608} textAnchor="middle" fontFamily="Arial, sans-serif" fontSize={27}
        opacity={drawn} fill={PALETTE.pencil}>Codex + Claude</text>
      <RoughDrawing seed={310 + beat.index} progress={drawn}
        options={{stroke: PALETTE.pencil, strokeWidth: 2}}
        build={(g, o) => Array.from({length: 5}, (_, i) => g.circle(850 + i * 55, 780, 14,
          {...o, fill: i < beat.index ? PALETTE.accent : PALETTE.cream, fillStyle: "solid"}))} />
    </svg>
  );
};
