import { beat5 } from "../../timeline/beats/beat5-outro";
import { PlaceholderBeat } from "../components/PlaceholderBeat";
import type { BeatProps } from "./types";

export const Beat5Outro: React.FC<BeatProps> = ({ language }) =>
  <PlaceholderBeat beat={beat5} language={language} />;
