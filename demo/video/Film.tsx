import { AbsoluteFill, interpolate, Sequence, useCurrentFrame, useVideoConfig } from "remotion";
import { FILM, toFrame, type Language } from "../timeline";
import { clamp } from "./anim";
import { BEAT_COMPONENTS } from "./beats";
import { Captions } from "./components/Captions";
import { Paper } from "./components/Paper";
import { DayLight, StoryClock } from "./components/DayLight";

export interface FilmProps extends Record<string, unknown> { language: Language }

export const Film: React.FC<FilmProps> = ({language}) => {
  const frame = useCurrentFrame();
  const {durationInFrames, fps} = useVideoConfig();
  const t = frame / fps;
  const opacity = interpolate(frame,
    [durationInFrames - toFrame(FILM.fadeOutSeconds), durationInFrames - 1], [1, 0], clamp);
  return (
    <AbsoluteFill>
      <Paper />
      <AbsoluteFill style={{opacity}}>
        <DayLight t={t} />
        {FILM.beats.map((beat) => {
          const Visual = BEAT_COMPONENTS[beat.key];
          return <Sequence key={beat.key} name={`Beat ${beat.index}: ${beat.title}`}
            from={toFrame(beat.start)} durationInFrames={toFrame(beat.end) - toFrame(beat.start)}>
            <Visual language={language} />
          </Sequence>;
        })}
        <StoryClock t={t} language={language} />
        <Captions language={language} />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
