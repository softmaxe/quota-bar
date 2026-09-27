import { RoughDrawing } from "../rough/RoughDrawing";
import { USAGE_FIXTURES } from "./fixtures";
import { Chevron, Frame, Label, PROVIDER_COLORS, ProviderTabs, Rule, UI_TEXT, type InterfaceProvider, type WindowPosition } from "./shared";

export interface CostSectionProps {
  provider?: InterfaceProvider;
  mode?: "cost" | "tokens";
  barsProgress?: number;
  pinnedDay?: number;
  showModels?: boolean;
}

/** The Local usage section at its native 720-pixel width. */
export const CostSection: React.FC<CostSectionProps> = ({ provider = "Claude", mode = "cost", barsProgress = 1, pinnedDay, showModels = false }) => {
  const usage = USAGE_FIXTURES[provider];
  const values = usage[mode];
  const max = Math.max(...values);
  const color = PROVIDER_COLORS[provider];
  const validPin = pinnedDay !== undefined && Number.isInteger(pinnedDay) && pinnedDay >= 0 && pinnedDay < 10;
  const day = validPin ? pinnedDay : 9;
  const models = provider === "Claude" && day === 7 ? USAGE_FIXTURES.Claude.models[7] : undefined;
  const total = (value: number) => mode === "cost" ? `$${value.toFixed(2)}` : `${value}M`;
  return <g>
    <Label x={30} y={36} size={28} weight={600}>Local usage</Label>
    <rect x={467} y={4} width={223} height={46} rx={9} fill="#eee7da" />
    <rect x={mode === "tokens" ? 470 : 582} y={7} width={105} height={40} rx={7} fill={UI_TEXT.panel} stroke={UI_TEXT.rule} />
    <Label x={524} y={35} size={23} anchor="middle">Tokens</Label>
    <Label x={636} y={35} size={23} anchor="middle">Cost</Label>
    <Label x={30} y={88} size={22} color={UI_TEXT.muted}>Today</Label>
    <Label x={366} y={88} size={22} color={UI_TEXT.muted}>Last 30 days</Label>
    <Label x={30} y={131} size={38} weight={600}>{total(values[9]!)}</Label>
    <Label x={366} y={131} size={38} weight={600}>{usage.month[mode]}</Label>
    <Rule y={151} width={660} />
    <Label x={30} y={187} size={22} color={UI_TEXT.muted}>Last 10 calendar days</Label>
    <Label x={690} y={187} size={22} color={UI_TEXT.muted} anchor="end">{mode === "cost" ? "Cost" : "Tokens"}</Label>
    {[0.5, 1].map((ratio) => <line key={ratio} x1={32} x2={690} y1={376 - 162 * ratio} y2={376 - 162 * ratio} stroke={UI_TEXT.rule} strokeOpacity={0.4} strokeDasharray="3 7" />)}
    {values.map((value, index) => {
      const progress = Math.min(1, Math.max(0, barsProgress * 10 - index));
      const height = value / max * 162 * progress;
      const selected = validPin && index === pinnedDay;
      return <g key={index}>
        {selected && <rect x={34 + index * 65.6} y={205} width={62} height={178} rx={7} fill={color} opacity={0.1} />}
        {height > 0 && <RoughDrawing seed={7940 + index} options={{ stroke: color, strokeWidth: selected ? 2.2 : 1.4, roughness: 0.5, fill: color, fillStyle: "hachure", fillWeight: 3.8, hachureGap: 4.3 }} deps={[height, color, selected]}
          build={(g, o) => [g.rectangle(46 + index * 65.6, 376 - height, 37, height, o)]} />}
      </g>;
    })}
    <Rule y={382} width={660} />
    <Label x={30} y={413} size={21} color={UI_TEXT.muted}>Sep 15</Label>
    <Label x={690} y={413} size={21} color={UI_TEXT.muted} anchor="end">Sep 24</Label>
    {validPin && <g>
      <Label x={30} y={457} size={25} weight={600}>Sep {15 + day}</Label>
      {models && <Label x={149} y={457} size={22} color={UI_TEXT.muted}>3 models</Label>}
      <Label x={690} y={457} size={30} weight={600} anchor="end">{total(values[day]!)}</Label>
      <Label x={690} y={489} size={21} anchor="end" color={UI_TEXT.muted}>{mode === "cost" ? `${usage.tokens[day]}M` : `$${usage.cost[day]!.toFixed(2)}`}</Label>
    </g>}
    <Rule y={508} width={660} />
    <Label x={30} y={544} size={23}>Model breakdown</Label>
    <Chevron x={667} y={530} open={showModels} />
    {showModels && models?.map((model, index) => <g key={model.name}>
      <Label x={30} y={584 + index * 34} size={22}>{model.name}</Label>
      <Label x={690} y={584 + index * 34} size={22} anchor="end" color={UI_TEXT.muted}>{model.tokens} · {model.cost}</Label>
    </g>)}
    <Label x={360} y={695} size={21} anchor="middle" color={UI_TEXT.muted}>API-rate estimate · Not a bill</Label>
  </g>;
};

/** A close view of the card's Local usage section, retaining its provider tabs. */
export const CostCard: React.FC<CostSectionProps & WindowPosition> = ({ x = 0, y = 0, width = 720, drawProgress = 1, provider = "Claude", ...props }) =>
  <svg x={x} y={y} width={width} height={800 * width / 720} viewBox="0 0 720 800" overflow="visible">
    <Frame width={720} height={800} seed={7949} progress={drawProgress} />
    <ProviderTabs provider={provider} width={720} />
    <g transform="translate(0 84)"><CostSection provider={provider} {...props} /></g>
  </svg>;
