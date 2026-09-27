import { beat3 } from "../../timeline/beats/beat3-reset";
import { quotaAt } from "../../timeline/quota";
import { ramp, useBeatTime } from "../anim";
import { RedPenArrow, RedPenTick } from "../annotations";
import { MenuBarRobot } from "../characters/MenuBarRobot";
import { storyClock } from "../components/DayLight";
import { HAND_FONT } from "../fonts";
import { MenuBar, QuotaCard } from "../interface";
import type { BeatProps } from "./types";

export const Beat3Reset: React.FC<BeatProps> = ({ language }) => {
  const {t} = useBeatTime(beat3);
  const state = quotaAt(t);
  const reset = t >= beat3.moments.reset;
  const fill = reset ? 100 * ramp(t, beat3.moments.reset, beat3.moments.filled) : undefined;
  const annotation = ramp(t, beat3.moments.annotate, beat3.moments.annotate + 0.65);
  const englishClock = storyClock(t, "en");
  return <svg width={1920} height={1080} style={{position: "absolute", inset: 0}}>
    <MenuBar x={300} y={155} width={1300} clock={`${englishClock.date} ${englishClock.time}`}
      icon={<MenuBarRobot x={24} y={46} t={t} scale={0.17} icon />} />
    <QuotaCard x={920} y={230} width={650} reading={state.reading} resetMode="clock" sessionFillPercent={fill} />
    <MenuBarRobot x={528} y={718} t={t} scale={1.3} />
    {state.runningLow && <>
      <text x={387} y={307} fontFamily={HAND_FONT} fontSize={37} fill="#b13c35" opacity={annotation}>
        {language === "zh" ? "10% 及以下" : "10% or less"}
      </text>
      <RedPenArrow from={{x: 730, y: 285}} to={{x: 1276, y: 196}} bend={-75} progress={annotation} />
    </>}
    {reset && <>
      <text x={394} y={328} fontFamily={HAND_FONT} fontSize={38} fill="#526e5f" opacity={ramp(t, 40, 40.5)}>
        {language === "zh" ? "继续工作" : "Back to work"}
      </text>
      <RedPenTick x={1612} y={343} size={64} progress={ramp(t, 40.6, beat3.moments.filled)} />
    </>}
  </svg>;
};
