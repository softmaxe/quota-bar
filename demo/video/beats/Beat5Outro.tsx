import { beat5 } from "../../timeline/beats/beat5-outro";
import { ramp, useBeatTime } from "../anim";
import { RedPenArrow, RedPenCircle, RedPenTick } from "../annotations";
import { MenuBarRobot } from "../characters/MenuBarRobot";
import { HAND_FONT } from "../fonts";
import { ExportSettings, ReportPage } from "../interface";
import fontMetrics from "../public/fonts/LXGWWenKai-Regular.subset.metrics.json";
import { RoughDrawing } from "../rough/RoughDrawing";
import { PALETTE } from "../theme";
import type { BeatProps } from "./types";

const INSTALL_COMMAND = "brew install --cask softmaxe/tap/quota-bar";
const REPOSITORY = "github.com/softmaxe/quota-bar";
const COPY = {
  en: {offline: "Offline HTML", bilingual: "One report,", languages: "two languages", install: "Install with Homebrew"},
  zh: {offline: "离线 HTML", bilingual: "一份报告", languages: "两种语言", install: "通过 Homebrew 安装"},
};

/** Text uses the bundled glyph advances so the writing wipe keeps its alignment. */
const WrittenText: React.FC<{
  id: string; text: string; x: number; y: number; size: number; progress: number; color?: string;
}> = ({id, text, x, y, size, progress, color = PALETTE.ink}) => {
  const advances = fontMetrics.advances as Record<string, number>;
  const width = [...text].reduce((sum, char) => sum + (advances[String(char.codePointAt(0))] ?? fontMetrics.unitsPerEm), 0)
    / fontMetrics.unitsPerEm * size;
  return <g>
    <defs><clipPath id={id}>
      <rect x={x - width / 2 - 8} y={y - size * 1.2} width={(width + 16) * progress} height={size * 1.6} />
    </clipPath></defs>
    <text x={x} y={y} fontFamily={HAND_FONT} fontSize={size} textAnchor="middle" fill={color} clipPath={`url(#${id})`}>{text}</text>
  </g>;
};

export const Beat5Outro: React.FC<BeatProps> = ({language}) => {
  const {t} = useBeatTime(beat5);
  const m = beat5.moments;
  const copy = COPY[language];
  const reportIn = ramp(t, m.openReport, m.reportDrawn);
  const reportOut = ramp(t, m.wave - 0.3, m.wave + 0.3);
  const turn = ramp(t, m.languageSwitch, m.pageTurned);
  const pageWidth = Math.max(0.015, Math.abs(Math.cos(turn * Math.PI)));
  const pageBend = Math.sin(turn * Math.PI);
  const outro = ramp(t, m.wave, m.wave + 0.5);
  const reportLanguage = turn < 0.5 ? "zh" : "en";

  return <svg width={1920} height={1080} viewBox="0 0 1920 1080">
    {t < m.reportDrawn && <g opacity={1 - reportIn}>
      <ExportSettings x={285} y={70} width={1075}
        status={t >= m.saved ? "saved" : t >= m.export ? "exporting" : "idle"}
        drawProgress={ramp(t, m.reveal, m.export)} />
      <WrittenText id="outro-offline" text={copy.offline} x={1585} y={325} size={35}
        progress={ramp(t, m.export, m.saved)} color={PALETTE.accent} />
      <RedPenArrow from={{x: 1545, y: 353}} to={{x: 1350, y: 455}} bend={-22}
        progress={ramp(t, m.export, m.saved)} seed={8401} />
      <RedPenTick x={945} y={651} size={42} progress={ramp(t, m.saved, m.saved + 0.3)} seed={8402} />
    </g>}

    {t >= m.openReport && t < m.wave + 0.3 && <g opacity={reportIn * (1 - reportOut)}>
      {/* The language changes at the narrow edge of a page turning on its spine. */}
      <g transform={`translate(880 435) scale(${pageWidth} 1) skewY(${-pageBend}) translate(-880 -435)`}>
        <ReportPage x={315} y={70} width={1130} language={reportLanguage} drawProgress={reportIn} />
        <path d="M 1396 70 L 1445 70 L 1445 119 Z" fill={PALETTE.paperShade} opacity={pageBend * 0.85} />
      </g>
      <WrittenText id="outro-bilingual" text={copy.bilingual} x={1638} y={307} size={33}
        progress={ramp(t, m.reportDrawn, m.reportDrawn + 0.45)} color={PALETTE.accent} />
      <WrittenText id="outro-languages" text={copy.languages} x={1638} y={353} size={33}
        progress={ramp(t, m.reportDrawn + 0.15, m.reportDrawn + 0.65)} color={PALETTE.accent} />
      <g opacity={1 - pageBend}>
        <RedPenArrow from={{x: 1582, y: 260}} to={{x: 1410, y: 184}} bend={24}
          progress={ramp(t, m.reportDrawn, m.reportDrawn + 0.5)} seed={8403} />
        <RedPenCircle x={1193} y={132} width={220} height={56}
          progress={ramp(t, m.reportDrawn, m.reportDrawn + 0.5)} seed={8404} />
      </g>
    </g>}

    <MenuBarRobot x={1615 + (960 - 1615) * outro} y={680 + (387 - 680) * outro}
      scale={0.8 + 0.15 * outro} t={t} draw={ramp(t, m.reveal, m.export)} seed={8450} />

    {t >= m.wave && <g opacity={outro}>
      <WrittenText id="outro-title" text="QuotaBar" x={960} y={493} size={76}
        progress={ramp(t, m.title, m.install)} />
      <WrittenText id="outro-install-label" text={copy.install} x={960} y={577} size={31}
        progress={ramp(t, m.install, m.install + 0.4)} color={PALETTE.pencil} />
      <WrittenText id="outro-install-command" text={INSTALL_COMMAND} x={960} y={641} size={47}
        progress={ramp(t, m.install, m.installWritten)} />
      <RoughDrawing seed={8405} progress={ramp(t, m.installWritten - 0.2, m.installWritten + 0.1)}
        options={{stroke: PALETTE.accent, strokeWidth: 2.8, roughness: 1.5}}
        build={(g, o) => [g.curve([[465, 662], [808, 669], [1120, 665], [1460, 662]], o)]} />
      <WrittenText id="outro-repository" text={REPOSITORY} x={960} y={741} size={38}
        progress={ramp(t, m.repository, m.repositoryWritten)} color={PALETTE.pencil} />
    </g>}
  </svg>;
};
