import type { Language } from "../../timeline";
import { RoughDrawing } from "../rough/RoughDrawing";
import { REPORT_FIXTURE } from "./fixtures";
import { Frame, Label, Rule, TrafficLights, UI_TEXT, type WindowPosition } from "./shared";

export const ReportPage: React.FC<WindowPosition & { language?: Language; chartProgress?: number }> = ({ x = 0, y = 0, width = 1190, drawProgress = 1, language = "zh", chartProgress = 1 }) => {
  const copy = REPORT_FIXTURE.copy[language];
  const points = REPORT_FIXTURE.days.map((value, index) => [72 + index * 174, 548 - value / 61 * 131] as [number, number]);
  return <svg x={x} y={y} width={width} height={765 * width / 1190} viewBox="0 0 1190 765" overflow="visible">
    <Frame width={1190} height={765} seed={7960} progress={drawProgress} />
    <TrafficLights />
    <Label x={595} y={35} size={21} anchor="middle" color={UI_TEXT.muted}>{REPORT_FIXTURE.filename}</Label>
    <Rule x={1} y={53} width={1188} />
    <Label x={40} y={101} size={28} weight={600}>QuotaBar</Label>
    <rect x={934} y={68} width={216} height={45} rx={7} fill="#eee7da" />
    <rect x={language === "zh" ? 937 : 1035} y={71} width={language === "zh" ? 96 : 111} height={39} rx={5} fill={UI_TEXT.panel} stroke={UI_TEXT.rule} />
    <Label x={984} y={99} size={24} anchor="middle">中文</Label>
    <Label x={1091} y={99} size={23} anchor="middle">English</Label>
    <Label x={40} y={158} size={29} weight={600}>{copy.version}</Label>
    <Label x={40} y={192} size={22} color={UI_TEXT.muted}>{copy.local}</Label>
    <Label x={658} y={153} size={22} color={UI_TEXT.muted}>{copy.headline}</Label>
    <Label x={658} y={191} size={26}>{REPORT_FIXTURE.start} → {REPORT_FIXTURE.end}</Label>
    <Rule x={40} y={216} width={1110} />
    <Label x={40} y={274} size={49} weight={600} color="#846729">{REPORT_FIXTURE.tokens}</Label>
    <Label x={40} y={311} size={24}>{copy.total}</Label>
    <Label x={459} y={274} size={49} weight={600}>{REPORT_FIXTURE.cost}</Label>
    <Label x={459} y={311} size={24}>{copy.cost}</Label>
    <Label x={1150} y={270} size={29} anchor="end">{REPORT_FIXTURE.coverage}</Label>
    <Label x={1150} y={307} size={23} anchor="end" color={UI_TEXT.muted}>{copy.coverage}</Label>
    <Label x={40} y={366} size={28} weight={600}>{copy.daily}</Label>
    <Label x={40} y={397} size={21} color={UI_TEXT.muted}>{copy.dailyNote}</Label>
    <Rule x={40} y={556} width={1110} />
    <RoughDrawing seed={7961} progress={chartProgress} options={{ stroke: "#9a7830", strokeWidth: 2.8, roughness: 0.65 }}
      build={(g, o) => [g.linearPath(points, o)]} />
    {points.map(([cx, cy], index) => chartProgress >= index / 6 && <circle key={index} cx={cx} cy={cy} r={index === 5 ? 7 : 5} fill={index < 2 ? UI_TEXT.panel : "#9a7830"} stroke="#9a7830" strokeWidth={2.5} />)}
    {chartProgress >= 5 / 6 && <Label x={points[5]![0]} y={points[5]![1] - 17} size={22} anchor="middle">61.0M</Label>}
    <Label x={40} y={583} size={20} color={UI_TEXT.muted}>Sep 19</Label>
    <Label x={1150} y={583} size={20} anchor="end" color={UI_TEXT.muted}>Sep 25</Label>
    <Label x={40} y={628} size={26} weight={600}>{copy.models}</Label>
    <Label x={760} y={628} size={26} weight={600}>{copy.composition}</Label>
    {REPORT_FIXTURE.models.map((name, index) => <g key={name}>
      <Label x={40 + (index % 2) * 331} y={662 + Math.floor(index / 2) * 57} size={21}>{name}</Label>
      <rect x={40 + (index % 2) * 331} y={674 + Math.floor(index / 2) * 57} width={245 * REPORT_FIXTURE.modelShares[index]!} height={8} rx={2} fill={["#a58a45", "#aaa375", "#8c9673", "#799082"][index]} />
    </g>)}
    {Array.from({ length: 60 }, (_, index) => <circle key={index} cx={769 + index % 15 * 25} cy={657 + Math.floor(index / 15) * 23} r={6} fill={index < 44 ? "#a58a45" : index < 52 ? "#aaa375" : "#799082"} />)}
  </svg>;
};
