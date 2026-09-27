import { AbsoluteFill, interpolateColors } from "remotion";
import type { Language } from "../../timeline";
import { storyNow } from "../../timeline/quota";
import { HAND_FONT } from "../fonts";

const CLOCK_ZONE = "Asia/Shanghai";

/** One story clock drives both the paper annotation and the product's reset countdowns. */
export function storyClock(t: number, language: Language): { date: string; time: string } {
  const now = storyNow(t);
  const locale = language === "zh" ? "zh-CN" : "en-US";
  return {
    date: new Intl.DateTimeFormat(locale, {timeZone: CLOCK_ZONE, weekday: "short", month: "short", day: "numeric"}).format(now),
    time: new Intl.DateTimeFormat(locale, {timeZone: CLOCK_ZONE, hour: "numeric", minute: "2-digit", hour12: true}).format(now),
  };
}

/** Static paper fibres show through broad, translucent watercolor strokes. */
export const DayLight: React.FC<{ t: number }> = ({t}) => {
  const color = interpolateColors(t, [0, 12, 30, 37, 40, 45, 61, 63, 74],
    ["#e6cd8d", "#e7d6a8", "#dfad6e", "#deaa70", "#d49483", "#8b9dab", "#8b9dab", "#b3a7a0", "#b3a7a0"]);
  return <AbsoluteFill style={{pointerEvents: "none", mixBlendMode: "multiply"}}>
    <svg width={1920} height={1080}>
      <defs>
        <filter id="daylight-watercolor" x="-20%" y="-30%" width="140%" height="160%">
          <feTurbulence type="fractalNoise" baseFrequency="0.009 0.015" numOctaves={2} seed={823} result="grain" />
          <feDisplacementMap in="SourceGraphic" in2="grain" scale={58} xChannelSelector="R" yChannelSelector="G" />
          <feGaussianBlur stdDeviation={20} />
        </filter>
      </defs>
      <g fill={color} filter="url(#daylight-watercolor)">
        <path d="M-80 46 C245-50 550 108 854 60 S1480-20 1990 142 L1990 445 C1510 411 1310 220 975 336 S390 228-80 408Z" opacity={0.26} />
        <path d="M-90 400 C190 301 450 454 720 479 C936 502 783 686 521 738 S103 701-90 782Z" opacity={0.2} />
        <path d="M1258 440 C1488 392 1676 473 1967 372 L1987 762 C1754 850 1550 737 1320 746 S1091 530 1258 440Z" opacity={0.14} />
      </g>
    </svg>
  </AbsoluteFill>;
};

/** Reserved bounds: x=1460..1800, y=48..145. Keep every Beat clear of this corner. */
export const StoryClock: React.FC<{ t: number; language: Language }> = ({t, language}) => {
  const clock = storyClock(t, language);
  return <svg width={1920} height={1080} style={{position: "absolute", inset: 0, pointerEvents: "none"}}>
    <g fontFamily={HAND_FONT} fill="#61564d" textAnchor="end" transform="rotate(0.7 1780 90)">
      <text x={1780} y={81} fontSize={26}>{clock.date}</text>
      <text x={1780} y={127} fontSize={38}>{clock.time}</text>
    </g>
  </svg>;
};
