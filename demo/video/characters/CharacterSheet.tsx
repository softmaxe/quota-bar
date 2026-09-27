import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import { QUOTA_MOMENTS, quotaAt, type RobotPose } from "../../timeline/quota";
import { Paper } from "../components/Paper";
import { HAND_FONT } from "../fonts";
import { RoughDrawing } from "../rough/RoughDrawing";
import { PALETTE } from "../theme";
import { MenuBarRobot } from "./MenuBarRobot";

const poses: {pose: RobotPose; label: string; at: number; detail: string}[] = [
  {pose: "coding", label: "Coding", at: 1, detail: "Antenna, blocky body, short legs"},
  {pose: "alarmed", label: "Alarmed", at: 6, detail: "Expression does not set the warning"},
  {pose: "sweating", label: "Running low", at: QUOTA_MOMENTS.runningLow, detail: "At most 10% left · reset still ahead"},
  {pose: "relieved", label: "Relieved", at: QUOTA_MOMENTS.reset, detail: "100% left · a new session"},
  {pose: "proud", label: "Proud", at: 48, detail: "The app's chevron eyes"},
  {pose: "waving", label: "Waving", at: 70, detail: "A small wave goodbye"},
];

/** Inspect every gesture together without rendering either complete Film. */
export const CharacterSheet: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const motion = frame / fps % 1;
  return <AbsoluteFill>
    <Paper />
    <svg width={1920} height={1080} style={{position: "absolute", inset: 0}}>
      <text x={100} y={113} fill={PALETTE.ink} fontFamily={HAND_FONT} fontSize={51}>Menu bar robot</text>
      <text x={102} y={155} fill={PALETTE.pencil} fontFamily={HAND_FONT} fontSize={25}>
        Six poses, one quota rule. The selected provider controls the red warning.
      </text>
      {poses.map(({pose, label, at, detail}, index) => {
        const x = 348 + index % 3 * 612;
        const y = 465 + Math.floor(index / 3) * 419;
        const state = quotaAt(at);
        return <g key={pose}>
          <RoughDrawing seed={700 + index} options={{stroke: PALETTE.pencil, strokeWidth: 1.3, roughness: 1.2}}
            build={(g, o) => [g.line(x - 227, y + 15, x + 228, y + 15, o)]} />
          <MenuBarRobot x={x} y={y} t={at + motion * 0.3} pose={pose} scale={0.92} seed={78} />
          <text x={x} y={y + 59} textAnchor="middle" fontFamily={HAND_FONT} fontSize={34} fill={PALETTE.ink}>{label}</text>
          <text x={x} y={y + 94} textAnchor="middle" fontFamily="Arial, sans-serif" fontSize={20} fill={PALETTE.pencil}>{detail}</text>
          <text x={x} y={y + 122} textAnchor="middle" fontFamily="Arial, sans-serif" fontSize={17} fill={PALETTE.pencil}>
            {state.provider} · {state.runningLow ? "running low" : "normal"}
          </text>
        </g>;
      })}
      <MenuBarRobot x={1700} y={153} t={18} icon scale={0.27} />
      <MenuBarRobot x={1794} y={153} t={QUOTA_MOMENTS.runningLow} icon scale={0.27} />
    </svg>
  </AbsoluteFill>;
};
