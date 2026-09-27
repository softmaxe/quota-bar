import type { ReactNode } from "react";
import { Frame, Label, UI_TEXT, type WindowPosition } from "./shared";

/** Supply the timeline-driven character in the icon slot; the bar never guesses its state. */
export const MenuBar: React.FC<WindowPosition & { clock?: string; icon?: ReactNode }> = ({ x = 0, y = 0, width = 1600, drawProgress = 1, clock = "Thu Sep 24 10:30 AM", icon }) =>
  <svg x={x} y={y} width={width} height={66 * width / 1600} viewBox="0 0 1600 66" overflow="visible">
    <Frame width={1600} height={66} seed={7970} progress={drawProgress} />
    {["Code", "File", "Edit", "Selection", "View", "Go", "Window", "Help"].map((label, index) => <Label key={label} x={[30, 118, 188, 264, 400, 482, 547, 670][index]!} y={43} size={24} weight={index === 0 ? 600 : 400}>{label}</Label>)}
    <g transform="translate(1188 9)">{icon}</g>
    <g transform="translate(1256 24)" stroke={UI_TEXT.ink} strokeWidth={1.7}>
      <rect width={29} height={17} rx={3} fill="none" />
      <rect x={3} y={3} width={20} height={11} rx={1} fill={UI_TEXT.ink} stroke="none" />
      <line x1={32} y1={5} x2={32} y2={12} />
    </g>
    <Label x={1570} y={42} size={22} anchor="end">{clock}</Label>
  </svg>;
