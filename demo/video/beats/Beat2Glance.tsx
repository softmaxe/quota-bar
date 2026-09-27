import { beat2, GLANCE_MOMENTS as M, GLANCE_NOTES } from "../../timeline/beats/beat2-glance";
import { quotaAt } from "../../timeline/quota";
import { ramp, useBeatTime } from "../anim";
import { RedPenArrow, RedPenCircle } from "../annotations";
import { MenuBarRobot } from "../characters/MenuBarRobot";
import { HAND_FONT } from "../fonts";
import { MenuBar, QuotaCard } from "../interface";
import { RoughDrawing } from "../rough/RoughDrawing";
import { PALETTE } from "../theme";
import type { BeatProps } from "./types";

const PEN = "#b13c35";
const hold = (t: number, start: number, end: number) => ramp(t, start, start + 0.25) * (1 - ramp(t, end - 0.25, end));

export const Beat2Glance: React.FC<BeatProps> = ({ language }) => {
  const {t} = useBeatTime(beat2);
  const state = quotaAt(t);
  const open = ramp(t, M.open, M.open + 0.45);
  // Move the card above the expanded details before they open, so no text enters the caption area.
  const zoom = ramp(t, M.paceOpen - 0.7, M.paceOpen - 0.15) * (1 - ramp(t, M.paceClose + 0.3, M.paceClose + 0.8));
  const card = {x: 910 - 120 * zoom, y: 250 - 154 * zoom - (1 - open) * 20, width: 650 - 40 * zoom};
  const scale = card.width / 650;
  const expanded = t >= M.paceOpen && t < M.paceClose + 0.3;
  const expansion = ramp(t, M.paceOpen, M.paceOpen + 0.45) * (1 - ramp(t, M.paceClose, M.paceClose + 0.3));
  const resetMode = t < M.resetClock ? "countdown" : "clock";
  const shortcuts = hold(t, M.showClaude - 0.15, M.paceOpen - 0.5) + hold(t, M.showCodex - 0.3, 30);
  const lastSwitch = t >= M.returnClaude ? M.returnClaude : t >= M.showCodex ? M.showCodex : t >= M.showClaude ? M.showClaude : M.bars;
  const bars = ramp(t, lastSwitch, lastSwitch + 0.7);
  const resetNote = hold(t, M.resetMark, M.showClaude - 0.2);
  const paceNote = hold(t, M.paceMark, M.paceClose);
  const menu = 1 - ramp(t, M.paceOpen - 0.8, M.paceOpen - 0.4) * (1 - ramp(t, M.paceClose + 0.3, M.paceClose + 0.8));
  const penProgress = ramp(t, M.resetMark, M.resetMark + 0.65);

  return <svg width={1920} height={1080} style={{position: "absolute", inset: 0}}>
    <defs>
      <clipPath id="beat2-card-reveal"><rect x={card.x - 6} y={card.y - 6} width={card.width + 12}
        height={(524 + 224 * expansion) * scale + 12} /></clipPath>
    </defs>
    <g opacity={menu}>
      <MenuBar x={160} y={155} width={1600}
        icon={<MenuBarRobot x={24} y={49} scale={0.19} t={t} icon />} />
    </g>

    <g opacity={open} clipPath="url(#beat2-card-reveal)">
      <QuotaCard reading={state.reading} {...card} drawProgress={open} barProgress={bars}
        showPace={expanded} resetMode={resetMode} showResetMenu={t >= M.resetMenu && t < M.resetClock}
        shortcut={shortcuts > 0 ? state.provider : undefined} />
    </g>

    <g opacity={hold(t, M.open + 0.1, M.resetMark)}>
      <text x={245} y={358} fontFamily={HAND_FONT} fontSize={40} fill={PALETTE.ink}>{GLANCE_NOTES.card[language]}</text>
      <RedPenArrow from={{x: 641, y: 389}} to={{x: 883, y: 309}} bend={28} progress={ramp(t, M.bars, M.bars + 0.65)} />
    </g>

    <g opacity={resetNote}>
      <text x={277} y={378} fontFamily={HAND_FONT} fontSize={41} fill={PEN}>
        {GLANCE_NOTES[t >= M.resetClock ? "clock" : "countdown"][language]}
      </text>
      <RedPenArrow from={{x: 622, y: 411}} to={{x: 949, y: 504}} bend={-25} progress={penProgress} />
      <g transform={`translate(${card.x} ${card.y}) scale(${scale})`}>
        <RedPenCircle x={49} y={231} width={197} height={49} progress={penProgress} seed={8121} />
      </g>
    </g>

    <g opacity={paceNote}>
      <text x={249} y={351} fontFamily={HAND_FONT} fontSize={42} fill={PEN}>{GLANCE_NOTES.pace[language]}</text>
      <text x={249} y={405} fontFamily={HAND_FONT} fontSize={29} fill={PALETTE.ink}>{GLANCE_NOTES.reserve[language]}</text>
      <RedPenArrow from={{x: 630, y: 446}} to={{x: card.x + 16 * scale, y: card.y + 594 * scale}} bend={-40}
        progress={ramp(t, M.paceMark, M.paceMark + 0.85)} />
      <g transform={`translate(${card.x} ${card.y}) scale(${scale})`}>
        <RoughDrawing seed={8122} progress={ramp(t, M.paceMark, M.paceMark + 0.85)}
          options={{stroke: PEN, strokeWidth: 3.4, roughness: 0.8}}
          build={(g, o) => [g.line(30, 608, 347, 608, o)]} />
      </g>
    </g>

    <g opacity={shortcuts}>
      <text x={246} y={310} fontFamily={HAND_FONT} fontSize={40} fill={PALETTE.ink}>{GLANCE_NOTES.shortcuts[language]}</text>
      {(["Codex", "Claude"] as const).map((provider, index) => {
        const active = state.provider === provider;
        const pressed = active && t - lastSwitch < 0.2;
        const keyX = 250 + index * 250;
        return <g key={provider} transform={`translate(${keyX} ${pressed ? 353 : 349})`}>
          <RoughDrawing seed={8124 + index} options={{stroke: active ? PEN : PALETTE.pencil,
            fill: active ? PALETTE.whitePaper : PALETTE.paper, fillStyle: "solid", strokeWidth: active ? 3.2 : 1.7, roughness: 0.8}}
            build={(g, o) => [g.rectangle(0, 0, 181, 96, o)]} />
          <text x={90} y={64} textAnchor="middle" fontFamily="Arial, sans-serif" fontSize={48} fill={active ? PEN : PALETTE.pencil}>
            {index === 0 ? "⌘1" : "⌘2"}
          </text>
          <text x={90} y={136} textAnchor="middle" fontFamily={HAND_FONT} fontSize={28} fill={PALETTE.ink}>{provider}</text>
        </g>;
      })}
    </g>

    <MenuBarRobot x={402} y={759} t={t} scale={0.94} pose="proud" />
    <Pointer x={1373} y={181} opacity={hold(t, M.open - 0.35, M.open + 0.5)} />
    <Pointer x={card.x + 236 * scale} y={card.y + 260 * scale} opacity={hold(t, M.resetMenu - 0.25, M.resetMenu + 0.5)} />
    <Pointer x={card.x + 231 * scale} y={card.y + 305 * scale} opacity={hold(t, M.resetClock - 0.2, M.resetClock + 0.5)} />
    <Pointer x={card.x + 261 * scale} y={card.y + 491 * scale}
      opacity={hold(t, M.paceOpen - 0.25, M.paceOpen + 0.5) + hold(t, M.paceClose - 0.25, M.paceClose + 0.3)} />
  </svg>;
};

const Pointer: React.FC<{x: number; y: number; opacity: number}> = ({x, y, opacity}) =>
  <g transform={`translate(${x} ${y}) rotate(-12)`} opacity={opacity}>
    <path d="M 0 0 L 0 30 L 8 23 L 15 38 L 22 34 L 15 20 L 27 20 Z"
      fill={PALETTE.graphite} stroke={PALETTE.cream} strokeWidth={2} strokeLinejoin="round" />
  </g>;
