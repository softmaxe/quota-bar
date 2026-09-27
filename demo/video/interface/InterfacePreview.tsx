import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import { QUOTA_MOMENTS, QUOTA_READINGS, quotaAt } from "../../timeline/quota";
import { Paper } from "../components/Paper";
import { HAND_FONT } from "../fonts";
import { RedPenArrow, RedPenCircle, RedPenStrike, RedPenTick } from "../annotations";
import { CostCard, EditorWindow, ExportSettings, MenuBar, QuotaCard, ReportPage } from ".";

const {cafeCodex: codex, cafeClaude: claude, lowClaude: exhausted} = QUOTA_READINGS;
const reset = quotaAt(QUOTA_MOMENTS.reset).reading;

export const INTERFACE_PREVIEW_STATES = [
  "Editor and menu bar", "Codex quota", "Claude pace details", "Reset date menu", "Limit reached", "Reset fill",
  "Local tokens", "Local cost", "Pinned day and models", "Export settings", "Export in progress", "Report saved", "Report in Chinese", "Report in English",
] as const;
export const INTERFACE_PREVIEW_SECONDS = INTERFACE_PREVIEW_STATES.length * 3;

export const InterfacePreview: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const index = Math.min(INTERFACE_PREVIEW_STATES.length - 1, Math.floor(frame / fps / 3));
  const local = frame / fps % 3;
  const reveal = Math.min(1, Math.max(0, (local - 0.25) / 0.8));
  return <AbsoluteFill>
    <Paper />
    <svg width={1920} height={1080} style={{ position: "absolute", inset: 0 }}>
      <text x={135} y={105} fontFamily={HAND_FONT} fontSize={42} fill="#3a2e2a">{INTERFACE_PREVIEW_STATES[index]}</text>
      {index === 0 && <>
        <MenuBar x={160} y={180} />
        <EditorWindow x={490} y={336} showLimit drawProgress={reveal} />
        <RedPenCircle x={526} y={739} width={339} height={70} progress={reveal} />
      </>}
      {index >= 1 && index <= 5 && <>
        <QuotaCard x={635} y={181} width={650} reading={index === 1 ? codex : index === 4 ? exhausted : index === 5 ? reset : claude}
          showPace={index === 2} resetMode={index === 3 ? "clock" : "countdown"} showResetMenu={index === 3}
          sessionFillPercent={index === 5 ? reveal * 100 : undefined} shortcut={index === 1 ? "Codex" : undefined} />
        {index === 1 && <RedPenArrow from={{x: 370, y: 520}} to={{x: 665, y: 445}} bend={-25} progress={reveal} />}
        {index === 2 && <RedPenArrow from={{x: 382, y: 798}} to={{x: 653, y: 716}} bend={-26} progress={reveal} />}
        {index === 3 && <RedPenCircle x={686} y={417} width={191} height={50} progress={reveal} />}
        {index === 4 && <>
          <text x={195} y={523} fontFamily={HAND_FONT} fontSize={30} fill="#6d655a">Strike-through</text>
          <RedPenStrike x={185} y={511} width={228} progress={reveal} />
        </>}
        {index === 5 && <RedPenTick x={1340} y={336} size={75} progress={reveal} />}
      </>}
      {index >= 6 && index <= 8 && <>
        <CostCard x={622} y={151} width={676} mode={index === 6 ? "tokens" : "cost"} barsProgress={index === 7 ? reveal : 1} pinnedDay={index === 8 ? 7 : undefined} showModels={index === 8} />
        {index === 8 && <RedPenArrow from={{x: 392, y: 877}} to={{x: 638, y: 774}} bend={-25} progress={reveal} />}
      </>}
      {index >= 9 && index <= 11 && <>
        <ExportSettings x={445} y={210} status={index === 9 ? "idle" : index === 10 ? "exporting" : "saved"} />
        <RedPenTick x={1510} y={650} size={65} progress={reveal} />
      </>}
      {index >= 12 && <>
        <ReportPage x={365} y={178} language={index === 12 ? "zh" : "en"} />
        <RedPenCircle x={1290} y={237} width={232} height={64} progress={reveal} />
      </>}
      <text x={135} y={1005} fontFamily={HAND_FONT} fontSize={27} fill="#6d655a">{index + 1} / {INTERFACE_PREVIEW_STATES.length}</text>
    </svg>
  </AbsoluteFill>;
};
