import { beat4 } from "../../timeline/beats/beat4-cost";
import { PlaceholderBeat } from "../components/PlaceholderBeat";
import type { BeatProps } from "./types";

export const Beat4Cost: React.FC<BeatProps> = ({ language }) =>
  <PlaceholderBeat beat={beat4} language={language} />;
