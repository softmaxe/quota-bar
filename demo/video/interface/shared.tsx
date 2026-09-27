import type { ReactNode } from "react";
import { RoughDrawing } from "../rough/RoughDrawing";
import { PALETTE } from "../theme";
import { HAND_FONT } from "../fonts";

export type InterfaceProvider = "Codex" | "Claude";
export const UI_FONT = `Arial, "PingFang SC", "Noto Sans CJK SC", ${HAND_FONT}, sans-serif`;
export const PROVIDER_COLORS = { Codex: "#377d87", Claude: "#a95c43" } as const;
export const UI_TEXT = { ink: PALETTE.ink, muted: "#6d655a", rule: "#b5a991", panel: PALETTE.whitePaper };
export interface WindowPosition { x?: number; y?: number; width?: number; drawProgress?: number }

export const Label: React.FC<{
  x: number; y: number; children: ReactNode; size?: number; color?: string;
  weight?: number; anchor?: "start" | "middle" | "end";
}> = ({ x, y, children, size = 24, color = UI_TEXT.ink, weight = 400, anchor = "start" }) =>
  <text x={x} y={y} fill={color} fontFamily={UI_FONT} fontSize={size} fontWeight={weight} textAnchor={anchor}>{children}</text>;

export const Frame: React.FC<{ width: number; height: number; seed: number; progress?: number; children?: ReactNode }> =
  ({ width, height, seed, progress = 1, children }) => <>
    <rect x={1} y={1} width={width - 2} height={height - 2} rx={18} fill={UI_TEXT.panel} />
    <RoughDrawing seed={seed} progress={progress} options={{ stroke: UI_TEXT.ink, strokeWidth: 2.1, roughness: 0.65, bowing: 0.4 }}
      deps={[width, height]} build={(g, o) => [g.path(`M 20 1 H ${width - 20} Q ${width - 1} 1 ${width - 1} 20 V ${height - 20} Q ${width - 1} ${height - 1} ${width - 20} ${height - 1} H 20 Q 1 ${height - 1} 1 ${height - 20} V 20 Q 1 1 20 1 Z`, o)]} />
    {children}
  </>;

export const Rule: React.FC<{ x?: number; y: number; width: number }> = ({ x = 30, y, width }) =>
  <line x1={x} x2={x + width} y1={y} y2={y} stroke={UI_TEXT.rule} strokeWidth={1} />;

export const TrafficLights: React.FC<{ y?: number }> = ({ y = 27 }) => <g>
  {["#ca725f", "#dab958", "#8da076"].map((fill, i) => <circle key={fill} cx={27 + i * 23} cy={y} r={6} fill={fill} stroke={UI_TEXT.muted} strokeWidth={0.8} />)}
</g>;

export const ProviderTabs: React.FC<{ provider: InterfaceProvider; width?: number; shortcut?: InterfaceProvider }> =
  ({ provider, width = 650, shortcut }) => {
    const tabWidth = (width - 60) / 2;
    return <g>
      <rect x={30} y={22} width={width - 60} height={51} rx={10} fill="#eee7da" />
      <rect x={32 + (provider === "Claude" ? tabWidth : 0)} y={24} width={tabWidth - 4} height={47} rx={8} fill={UI_TEXT.panel} stroke={UI_TEXT.rule} />
      {(["Codex", "Claude"] as const).map((name, i) => <g key={name}>
        <circle cx={60 + i * tabWidth} cy={47} r={5} fill={PROVIDER_COLORS[name]} />
        <Label x={77 + i * tabWidth} y={56} size={26} weight={provider === name ? 600 : 400}>{name}</Label>
        {shortcut === name && <Label x={tabWidth * (i + 1) + 8} y={55} size={22} anchor="end" color={UI_TEXT.muted}>{i === 0 ? "⌘1" : "⌘2"}</Label>}
      </g>)}
    </g>;
  };

export const ResetIcon: React.FC<{ x: number; y: number }> = ({ x, y }) => <g transform={`translate(${x} ${y})`} fill="none" stroke={UI_TEXT.muted} strokeWidth={1.9} strokeLinecap="round" strokeLinejoin="round">
  <path d="M 17 10 A 8 8 0 1 1 14 4 M 17 0 V 6 H 11" />
</g>;

export const Chevron: React.FC<{ x: number; y: number; open?: boolean }> = ({ x, y, open }) =>
  <path d={open ? `M ${x} ${y} l 7 7 l 7 -7` : `M ${x} ${y - 4} l 7 7 l -7 7`} fill="none" stroke={UI_TEXT.muted} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />;
