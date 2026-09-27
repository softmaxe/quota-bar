import { RoughDrawing } from "../rough/RoughDrawing";
import { Chevron, Frame, Label, PROVIDER_COLORS, ProviderTabs, ResetIcon, Rule, UI_TEXT, type InterfaceProvider, type WindowPosition } from "./shared";

/** Structurally compatible with the timeline's QuotaReading. */
export interface InterfaceQuotaWindow {
  remainingPercent: number;
  summary: string;
  countdown: string;
  resetLabel: string;
  pace?: { title: string; expected: string; headroom: string };
}
export interface InterfaceQuotaReading {
  provider: InterfaceProvider;
  plan: string;
  session: InterfaceQuotaWindow | null;
  weekly: InterfaceQuotaWindow | null;
}
export interface QuotaCardProps extends WindowPosition {
  reading: InterfaceQuotaReading;
  showPace?: boolean;
  resetMode?: "countdown" | "clock";
  sessionFillPercent?: number;
  weeklyFillPercent?: number;
  barProgress?: number;
  showResetMenu?: boolean;
  shortcut?: InterfaceProvider;
}

const QuotaRow: React.FC<{ name: string; row: InterfaceQuotaWindow | null; y: number; color: string; fillPercent?: number; barProgress: number; resetMode: "countdown" | "clock"; seed: number }> =
  ({ name, row, y, color, fillPercent, barProgress, resetMode, seed }) => {
    if (!row) return <Label x={30} y={y} color={UI_TEXT.muted}>{name}</Label>;
    const fill = 590 * Math.min(1, Math.max(0, (fillPercent ?? row.remainingPercent) / 100)) * Math.min(1, Math.max(0, barProgress));
    return <g>
      <Label x={30} y={y} size={26} weight={600}>{name}</Label>
      <Label x={620} y={y} size={34} weight={600} anchor="end">{row.remainingPercent}% left</Label>
      <rect x={30} y={y + 23} width={590} height={23} rx={5} fill="#e9e2d5" />
      {fill > 0 && <rect x={30} y={y + 23} width={fill} height={23} rx={5} fill={color} />}
      <RoughDrawing seed={seed} options={{ stroke: color, strokeWidth: 1.4, roughness: 0.7 }} deps={[y]}
        build={(g, o) => [g.rectangle(30, y + 23, 590, 23, o)]} />
      <Label x={30} y={y + 72} size={23} color={UI_TEXT.muted}>{row.summary}</Label>
      <ResetIcon x={32} y={y + 90} />
      <Label x={65} y={y + 107} size={24}>{resetMode === "clock" ? row.resetLabel : row.countdown}</Label>
      <Chevron x={226} y={y + 96} open />
    </g>;
  };

export const QuotaCard: React.FC<QuotaCardProps> = ({ reading, x = 0, y = 0, width = 650, showPace = false, resetMode = "countdown", sessionFillPercent, weeklyFillPercent, barProgress = 1, drawProgress = 1, showResetMenu = false, shortcut }) => {
  const height = showPace ? 748 : 524;
  const color = PROVIDER_COLORS[reading.provider];
  return <svg x={x} y={y} width={width} height={height * width / 650} viewBox={`0 0 650 ${height}`} overflow="visible">
    <Frame width={650} height={height} seed={7901} progress={drawProgress} />
    <ProviderTabs provider={reading.provider} shortcut={shortcut} />
    <Label x={30} y={107} size={22} color={UI_TEXT.muted}>Updated just now</Label>
    <Label x={620} y={107} size={22} anchor="end" color={UI_TEXT.muted}>{reading.plan}</Label>
    <QuotaRow name="Session" row={reading.session} y={156} color={color} fillPercent={sessionFillPercent} barProgress={barProgress} resetMode={resetMode} seed={7902} />
    <QuotaRow name="Weekly" row={reading.weekly} y={328} color={color} fillPercent={weeklyFillPercent} barProgress={barProgress} resetMode={resetMode} seed={7903} />
    <Rule y={463} width={590} />
    <Chevron x={31} y={485} open={showPace} />
    <Label x={58} y={494} size={23}>Usage pace details</Label>
    {showPace && [reading.session, reading.weekly].map((row, index) => <g key={index}>
      <Label x={30} y={537 + index * 103} size={23} weight={600}>{row?.pace?.title ?? (index === 0 ? "Session" : "Weekly")}</Label>
      <Label x={30} y={567 + index * 103} size={22} color={UI_TEXT.muted}>{row?.pace?.expected ?? row?.summary}</Label>
      <Label x={30} y={597 + index * 103} size={22} color={UI_TEXT.muted}>{row?.pace?.headroom}</Label>
    </g>)}
    {showResetMenu && <g>
      <rect x={65} y={272} width={260} height={55} rx={8} fill={UI_TEXT.panel} stroke={UI_TEXT.rule} />
      <Label x={84} y={307} size={23}>{resetMode === "countdown" ? "Show reset date" : "Show countdown"}</Label>
    </g>}
  </svg>;
};
