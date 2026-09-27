import { beat1 } from "../../timeline/beats/beat1-quota";
import { quotaAt } from "../../timeline/quota";
import { ramp, useBeatTime } from "../anim";
import { RedPenArrow, RedPenCircle } from "../annotations";
import { MenuBarRobot } from "../characters/MenuBarRobot";
import { HAND_FONT } from "../fonts";
import { EditorWindow, MenuBar } from "../interface";
import { PALETTE } from "../theme";
import type { BeatProps } from "./types";

const smooth = (progress: number) => progress * progress * (3 - 2 * progress);

/** The editor and menu bar share a camera; foreground writing stays on the paper. */
export const Beat1Quota: React.FC<BeatProps> = ({language}) => {
  const {t} = useBeatTime(beat1);
  const state = quotaAt(t);
  const m = beat1.moments;
  const focus = smooth(ramp(t, m.camera, m.cameraComplete));
  const drawing = ramp(t, m.editor, m.editor + 0.8);
  const editorOpacity = 1 - ramp(t, m.camera + 0.1, m.cameraComplete - 0.15);
  const note = ramp(t, m.note, m.note + 0.6);
  const menuNote = ramp(t, m.menuNote, m.menuNoteComplete);
  const clock = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Shanghai", hour: "numeric", minute: "2-digit", hour12: true,
  }).format(new Date(state.nowMs));

  return <svg width={1920} height={1080}>
    <defs>
      <clipPath id="beat1-scene"><rect x={115} y={160} width={1690} height={670} /></clipPath>
      <clipPath id="beat1-rate-note"><rect x={1160} y={686} width={410 * note} height={110} /></clipPath>
      <clipPath id="beat1-menu-note"><rect x={865} y={578} width={500 * menuNote} height={100} /></clipPath>
    </defs>
    <g clipPath="url(#beat1-scene)">
      <g transform={`translate(${-925 * focus} ${122.5 * focus}) scale(${1 + 0.5 * focus})`}>
        <MenuBar x={160} y={185} width={1600} clock={`Thu Sep 24 ${clock}`} drawProgress={drawing}
          icon={<MenuBarRobot x={24} y={49} scale={0.175} icon t={t}
            draw={ramp(t, m.icon, m.iconComplete)} />} />
        <g opacity={editorOpacity}>
          <EditorWindow x={600} y={250} width={1040} drawProgress={drawing} showLimit={t >= m.limit} />
          <MenuBarRobot x={345} y={690} scale={1.32} t={t} pose={state.pose} draw={drawing} />
          <RedPenCircle x={641} y={690} width={462} height={98}
            progress={ramp(t, m.circle, m.circleComplete)} />
          <g clipPath="url(#beat1-rate-note)">
            <text x={1240} y={727} fontFamily={HAND_FONT} fontSize={35} fill={PALETTE.accent}
              transform="rotate(-3 1240 727)">{language === "en" ? "Already?" : "这就用完了？"}</text>
          </g>
          <RedPenArrow from={{x: 1275, y: 750}} to={{x: 1110, y: 754}} bend={-13} progress={note} />
        </g>
      </g>
    </g>
    <g clipPath="url(#beat1-menu-note)">
      <text x={1112} y={650} textAnchor="middle" fontFamily={HAND_FONT} fontSize={61}
        fill={PALETTE.ink} transform="rotate(-2 1112 650)">QuotaBar</text>
    </g>
    <RedPenArrow from={{x: 1112, y: 580}} to={{x: 1133, y: 507}}
      bend={-16} progress={menuNote} />
  </svg>;
};
