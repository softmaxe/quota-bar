import { beat2 } from "../../timeline/beats/beat2-glance";
import { PlaceholderBeat } from "../components/PlaceholderBeat";
import type { BeatProps } from "./types";

export const Beat2Glance: React.FC<BeatProps> = ({ language }) =>
  <PlaceholderBeat beat={beat2} language={language} />;
