import { execFileSync } from "node:child_process";
import { staleReason } from "../../scripts/build-state";
import { ROOT } from "../../scripts/paths";

export default function setup(): void {
  const reason = staleReason();
  if (!reason) return;
  console.log(`Film tests: ${reason}; rebuilding both films`);
  execFileSync("npm", ["run", "build"], {cwd: ROOT, stdio: "inherit"});
  const remaining = staleReason();
  if (remaining) throw new Error(`Build did not refresh all outputs: ${remaining}`);
}
