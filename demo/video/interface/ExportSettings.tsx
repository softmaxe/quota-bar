import { Frame, Label, Rule, TrafficLights, UI_TEXT, type WindowPosition } from "./shared";
import { REPORT_FIXTURE } from "./fixtures";

export type ExportStatus = "idle" | "exporting" | "saved";
export const ExportSettings: React.FC<WindowPosition & { status?: ExportStatus }> = ({ x = 0, y = 0, width = 1030, drawProgress = 1, status = "idle" }) =>
  <svg x={x} y={y} width={width} height={690 * width / 1030} viewBox="0 0 1030 690" overflow="visible">
    <Frame width={1030} height={690} seed={7950} progress={drawProgress} />
    <TrafficLights />
    <Label x={515} y={36} size={23} anchor="middle" weight={600}>Export</Label>
    <Rule x={1} y={53} width={1028} />
    <rect x={610} y={66} width={143} height={43} rx={8} fill="#e8e1d3" />
    {["General", "Pricing", "Export"].map((tab, index) => <Label key={tab} x={350 + index * 164} y={95} size={23} weight={index === 2 ? 600 : 400} anchor="middle">{tab}</Label>)}
    <Label x={40} y={152} size={26} weight={600}>Report</Label>
    <rect x={29} y={171} width={972} height={229} rx={9} fill="#f4efe5" />
    {[["Layout", "Usage trends"], ["Period", "Last 7 days"], ["Scope", "All stored sources"], ["Format", "Bilingual HTML (offline)"]].map(([label, value], index) => <g key={label}>
      <Label x={48} y={210 + index * 54} size={24}>{label}</Label>
      <Label x={973} y={210 + index * 54} size={24} anchor="end">{value}</Label>
      {index < 3 && <Rule x={47} y={228 + index * 54} width={936} />}
    </g>)}
    <Label x={40} y={438} size={23} color={UI_TEXT.muted}>Switch between Chinese and English in the report. Prices saved local usage</Label>
    <Label x={40} y={471} size={23} color={UI_TEXT.muted}>at each day's rates; cache costs are included but not broken out.</Label>
    <Label x={40} y={522} size={24}>Open after export</Label>
    <rect x={927} y={496} width={60} height={32} rx={16} fill="#78927d" />
    <circle cx={971} cy={512} r={12} fill={UI_TEXT.panel} />
    <Rule x={30} y={549} width={970} />
    <Label x={40} y={584} size={status === "idle" ? 21 : 22} color={status === "saved" ? "#4c745b" : UI_TEXT.muted}>
      {status === "idle" ? "Choose a period, then export an offline report." : status === "exporting" ? "Exporting report…" : `Saved ${REPORT_FIXTURE.filename}`}
    </Label>
    <rect x={749} y={558} width={239} height={45} rx={8} fill="#456d78" opacity={status === "exporting" ? 0.6 : 1} />
    <Label x={869} y={588} size={23} color="#fffdf6" anchor="middle">Export Report…</Label>
    {status === "saved" && ["Open Report", "Show in Finder"].map((label, index) => <g key={label}>
      <rect x={40 + index * 199} y={618} width={183} height={43} rx={8} fill="#eee7da" stroke={UI_TEXT.rule} />
      <Label x={132 + index * 199} y={647} size={23} anchor="middle">{label}</Label>
    </g>)}
  </svg>;
