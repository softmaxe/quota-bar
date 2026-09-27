import { COST_NOTES } from "../../../timeline/beats/beat4-cost";
import type { Language } from "../../../timeline";
import { HAND_FONT } from "../../fonts";
import { RoughDrawing } from "../../rough/RoughDrawing";
import { PALETTE } from "../../theme";

/** A paper ledger beside the app, not an invented app window or control. */
export const PriceBookLedger: React.FC<{language: Language; progress: number; textProgress: number}> =
  ({language, progress, textProgress}) => <g transform="translate(95 254) scale(0.84) rotate(-2 330 175)">
    <path d="M 26 18 L 630 8 L 641 335 L 14 345 Z" fill={PALETTE.cream} opacity={progress} />
    <RoughDrawing seed={8340} progress={progress}
      options={{stroke: PALETTE.pencil, strokeWidth: 2.2, roughness: 1.15}}
      build={(g, o) => [g.path("M 26 18 L 630 8 L 641 335 L 14 345 Z", o), g.line(58, 18, 48, 338, o),
        ...[118, 166, 216, 266, 316].map((y) => g.line(77, y, 606, y, {...o, stroke: "#98a9ac", strokeWidth: 1.2})),
        g.line(263, 87, 261, 312, {...o, stroke: "#98a9ac", strokeWidth: 1.2})]} />
    <g opacity={textProgress} fontFamily={HAND_FONT} fill={PALETTE.ink}>
      <text x={84} y={76} fontSize={39}>{COST_NOTES.book[language]}</text>
      {language === "zh" && <text x={268} y={74} fontSize={23} fill={PALETTE.pencil}>Price book</text>}
      <text x={88} y={110} fontSize={24}>{COST_NOTES.date[language]}</text>
      <text x={290} y={110} fontSize={24}>{COST_NOTES.rates[language]}</text>
      {[20, 21, 22].map((day, index) => <g key={day}>
        <text x={88} y={154 + index * 50} fontSize={28}>{language === "zh" ? `9月${day}日` : `Sep ${day}`}</text>
        <text x={290} y={154 + index * 50} fontSize={28}>{COST_NOTES.row[language]}</text>
      </g>)}
      <text x={85} y={306} fontSize={27}>{COST_NOTES.note[language]}</text>
    </g>
  </g>;
