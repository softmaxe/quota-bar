import { beat3 } from "../../timeline/beats/beat3-reset";
import { PlaceholderBeat } from "../components/PlaceholderBeat";
import type { BeatProps } from "./types";

export const Beat3Reset: React.FC<BeatProps> = ({ language }) =>
  <PlaceholderBeat beat={beat3} language={language} />;
