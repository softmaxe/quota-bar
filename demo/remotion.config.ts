// Config for the Remotion CLI (`npm run studio`). The build script
// (scripts/build.ts) passes the same entry point and public dir explicitly.
import { Config } from "@remotion/cli/config";

Config.setEntryPoint("video/index.ts");
Config.setPublicDir("video/public");
Config.setVideoImageFormat("jpeg");
