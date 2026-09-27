import { beat1 } from "../../timeline/beats/beat1-quota";
import { PlaceholderBeat } from "../components/PlaceholderBeat";
import type { BeatProps } from "./types";

export const Beat1Quota: React.FC<BeatProps> = ({ language }) =>
  <PlaceholderBeat beat={beat1} language={language} />;
