import { AbsoluteFill } from "remotion";
import { beat4, COST_NOTES, COST_PINNED_DAY } from "../../timeline/beats/beat4-cost";
import { ramp, useBeatTime } from "../anim";
import { RedPenArrow, RedPenCircle, RedPenTick } from "../annotations";
import { MenuBarRobot } from "../characters/MenuBarRobot";
import { HAND_FONT } from "../fonts";
import { CostCard, MenuBar } from "../interface";
import { PALETTE } from "../theme";
import { PriceBookLedger } from "./cost/PriceBookLedger";
import type { BeatProps } from "./types";

const CARD = {x: 780, y: 62, width: 664};
const SCALE = CARD.width / 720;
const point = (x: number, y: number) => ({x: CARD.x + x * SCALE, y: CARD.y + y * SCALE});

/** Beat 4 keeps the real Local usage card readable while the ledger explains its rates. */
export const Beat4Cost: React.FC<BeatProps> = ({ language }) => {
  const {t} = useBeatTime(beat4);
  const m = beat4.moments;
  const card = ramp(t, m.cardOpen, m.cardOpen + 0.45);
  const ledger = ramp(t, m.ledger, m.ledger + 0.9);
  const cost = t >= m.costMode;
  const pinned = t >= m.pinDay;
  const models = t >= m.modelsOpen;
  const pin = point(46 + COST_PINNED_DAY * 65.6 + 18.5, 84 + 282);
  const cursorAt = t < m.pinDay - 0.7 ? point(636, 111) : t < m.modelsOpen - 0.5 ? pin : point(667, 618);
  const clickAt = t < m.pinDay - 0.7 ? m.costMode : t < m.modelsOpen - 0.5 ? m.pinDay : m.modelsOpen;
  const cursor = t >= m.costMode - 0.35 && t < m.modelsOpen + 0.45;
  return <AbsoluteFill>
    <svg width={1920} height={1080} viewBox="0 0 1920 1080">
      <g opacity={1 - ramp(t, m.cardOpen, m.cardOpen + 0.35)}>
        <MenuBar x={140} y={154} width={1640} clock="Thu Sep 24 9:40 PM"
          icon={<MenuBarRobot x={24} y={51} t={t} scale={0.19} icon />} />
      </g>
      <g opacity={card}>
        <CostCard {...CARD} provider="Claude" mode={cost ? "cost" : "tokens"}
          barsProgress={cost ? ramp(t, m.barsStart, m.barsEnd) : 0}
          pinnedDay={pinned ? COST_PINNED_DAY : undefined} showModels={models} drawProgress={card} />
        {cost && <RedPenCircle x={CARD.x + 575 * SCALE} y={CARD.y + 84 * SCALE} width={120 * SCALE} height={48 * SCALE}
          progress={ramp(t, m.costMode, m.costMode + 0.5)} seed={8310} />}
        {pinned && <RedPenCircle x={CARD.x + 20 * SCALE} y={CARD.y + 513 * SCALE} width={240 * SCALE} height={42 * SCALE}
          progress={ramp(t, m.pinDay, m.pinDay + 0.45)} seed={8311} />}
        {models && <RedPenTick x={1468} y={623} size={41} progress={ramp(t, m.modelsMarked, m.modelsMarked + 0.4)} seed={8312} />}
      </g>

      <g opacity={card * (1 - ledger)}>
        <text x={348} y={268} textAnchor="middle" fontFamily={HAND_FONT} fontSize={35} fill={PALETTE.ink}>
          {pinned ? COST_NOTES.pinned[language] : COST_NOTES.days[language]}
        </text>
        <RedPenArrow from={{x: 575, y: 307}} to={pinned ? point(30, 539) : point(30, 377)} bend={-22}
          progress={ramp(t, pinned ? m.pinDay : m.barsStart, (pinned ? m.pinDay : m.barsStart) + 0.6)} seed={8313} />
      </g>

      <PriceBookLedger language={language} progress={ledger} textProgress={ramp(t, m.ledger + 0.45, m.ledgerNote)} />
      <RedPenCircle x={151} y={432} width={420} height={48} progress={ramp(t, m.ratesMarked, m.ratesMarked + 0.6)} seed={8314} />
      <RedPenArrow from={{x: 642, y: 450}} to={point(10, 706)} bend={-20}
        progress={ramp(t, m.ratesMarked + 0.25, m.ratesMarked + 1)} seed={8315} />
      <MenuBarRobot x={1658} y={770} t={t} pose="proud" scale={1.05} draw={card} seed={8380} />

      {cursor && <g transform={`translate(${cursorAt.x} ${cursorAt.y})`} opacity={1 - ramp(t, m.modelsOpen + 0.15, m.modelsOpen + 0.45)}>
        <circle r={8 + ramp(t, clickAt, clickAt + 0.25) * 16} fill="none" stroke={PALETTE.accent} strokeWidth={2}
          opacity={t >= clickAt ? 1 - ramp(t, clickAt, clickAt + 0.25) : 0} />
        <path d="M 0 0 L 0 25 L 7 18 L 13 30 L 19 27 L 13 15 L 23 15 Z" fill={PALETTE.whitePaper} stroke={PALETTE.graphite} strokeWidth={2} />
      </g>}
    </svg>
  </AbsoluteFill>;
};
