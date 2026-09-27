import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { beforeAll, describe, expect, it } from "vitest";
import { FILM, LANGUAGES } from "../../timeline";
import { PATHS } from "../../scripts/paths";
import { reviewFrameTimes } from "../../scripts/review-frames";

interface Stream {
  codec_type: string;
  codec_name: string;
  width?: number;
  height?: number;
  r_frame_rate?: string;
  duration: string;
}

function volume(args: string[]): {mean: number; max: number} {
  const result = spawnSync("ffmpeg", ["-hide_banner", "-nostats", ...args,
    "-af", "volumedetect", "-vn", "-f", "null", "-"], {encoding: "utf8"});
  if (result.error || result.status !== 0) throw new Error(`ffmpeg volume check failed: ${result.error ?? result.stderr}`);
  const read = (kind: string): number => {
    const match = new RegExp(`${kind}_volume: (-?[\\d.]+|-inf) dB`).exec(result.stderr);
    if (!match) throw new Error(`ffmpeg did not report ${kind}_volume: ${result.stderr}`);
    return match[1] === "-inf" ? -Infinity : Number(match[1]);
  };
  return {mean: read("mean"), max: read("max")};
}

for (const language of LANGUAGES) describe(`built ${language} Film`, () => {
  let streams: Stream[];
  let duration: number;
  beforeAll(() => {
    const probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format",
      "-of", "json", PATHS.film(language)], {encoding: "utf8"}));
    streams = probe.streams;
    duration = Number(probe.format.duration);
  });

  it("lasts 75 seconds with matching audio and video durations", () => {
    expect(Math.abs(duration - FILM.durationSeconds)).toBeLessThanOrEqual(0.1);
    for (const stream of streams) expect(Math.abs(Number(stream.duration) - FILM.durationSeconds)).toBeLessThanOrEqual(0.1);
  });

  it("has exactly two streams: H.264 1080p30 video and AAC audio", () => {
    expect(streams).toHaveLength(2);
    expect(streams.filter((s) => s.codec_type === "video")).toHaveLength(1);
    expect(streams.filter((s) => s.codec_type === "audio")).toHaveLength(1);
    expect(streams.find((s) => s.codec_type === "video")).toMatchObject({
      codec_name: "h264", width: 1920, height: 1080, r_frame_rate: "30/1",
    });
    expect(streams.find((s) => s.codec_type === "audio")!.codec_name).toBe("aac");
  });

  it("has an audible soundtrack and fades below -40 dB in the last second", () => {
    expect(volume(["-i", PATHS.film(language)]).max).toBeGreaterThan(-20);
    expect(volume(["-sseof", "-1", "-i", PATHS.film(language)]).mean).toBeLessThan(-40);
  });

  it("includes valid 1920x1080 PNG review frames for every scheduled moment", () => {
    for (const {name} of reviewFrameTimes()) {
      const png = fs.readFileSync(path.join(PATHS.framesDir(language), `${name}.png`));
      expect(png.subarray(0, 8).toString("hex")).toBe("89504e470d0a1a0a");
      expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([FILM.width, FILM.height]);
    }
  });
});
