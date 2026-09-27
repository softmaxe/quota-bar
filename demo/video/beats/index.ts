import type { ComponentType } from "react";
import type { BeatKey } from "../../timeline";
import { Beat1Quota } from "./Beat1Quota";
import { Beat2Glance } from "./Beat2Glance";
import { Beat3Reset } from "./Beat3Reset";
import { Beat4Cost } from "./Beat4Cost";
import { Beat5Outro } from "./Beat5Outro";
import type { BeatProps } from "./types";

export const BEAT_COMPONENTS: Record<BeatKey, ComponentType<BeatProps>> = {
  quota: Beat1Quota, glance: Beat2Glance, reset: Beat3Reset, cost: Beat4Cost, outro: Beat5Outro,
};
