import { AbsoluteFill, Sequence } from "remotion";
import { allCaptions, toFrame, type Language } from "../../timeline";
import { HandwrittenCaption } from "./HandwrittenCaption";

export const Captions: React.FC<{language: Language}> = ({language}) => (
  <AbsoluteFill>
    {allCaptions().map((caption) => (
      <Sequence key={caption.id} from={toFrame(caption.start)}
        durationInFrames={toFrame(caption.end) - toFrame(caption.start)} layout="none">
        <HandwrittenCaption caption={caption} language={language} />
      </Sequence>
    ))}
  </AbsoluteFill>
);
