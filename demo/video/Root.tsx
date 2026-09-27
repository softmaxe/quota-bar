import { Composition } from "remotion";
import { FILM, LANGUAGES, toFrame } from "../timeline";
import { Film } from "./Film";
import { loadFonts } from "./fonts";

loadFonts();

export const Root: React.FC = () => <>
  {LANGUAGES.map((language) => <Composition key={language} id={`Film-${language}`} component={Film}
    defaultProps={{language}} durationInFrames={toFrame(FILM.durationSeconds)}
    fps={FILM.fps} width={FILM.width} height={FILM.height} />)}
</>;
