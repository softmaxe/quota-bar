import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { FILM } from "../timeline";
import { PATHS } from "./paths";

export function exportTimeline(outFile = PATHS.timelineJson): string {
  fs.mkdirSync(path.dirname(outFile), {recursive: true});
  fs.writeFileSync(outFile, JSON.stringify(FILM, null, 2) + "\n");
  return outFile;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(`Wrote ${exportTimeline(process.argv[2])}`);
}
