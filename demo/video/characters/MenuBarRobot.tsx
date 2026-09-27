import { quotaAt, type RobotPose } from "../../timeline/quota";
import { RoughDrawing } from "../rough/RoughDrawing";
import { PALETTE } from "../theme";

export type { RobotPose } from "../../timeline/quota";

export interface MenuBarRobotProps {
  /** Ground point between the feet in the parent SVG. */
  x: number;
  y: number;
  /** Absolute Film time. This controls color even when pose is overridden. */
  t: number;
  scale?: number;
  pose?: RobotPose;
  draw?: number;
  opacity?: number;
  seed?: number;
  /** The compact app silhouette, without limbs or the laptop. */
  icon?: boolean;
}

const BODY = "M -105 -42 L -105 -146 L -86 -146 L -86 -175 L -65 -175 L -65 -188 L 65 -188 L 65 -175 L 86 -175 L 86 -146 L 105 -146 L 105 -42 Z";
const sub = (value: number, from: number, to: number) => Math.min(1, Math.max(0, (value - from) / (to - from)));

/**
 * The MDI robot-excited antenna, ears and chevron face in the paper Film's
 * blocky pencil style. All geometry has fixed seeds; only gestures move.
 * Place this component inside an SVG. A scale of 1 gives a 210px-wide body.
 */
export const MenuBarRobot: React.FC<MenuBarRobotProps> = ({
  x, y, t, scale = 1, pose: selectedPose, draw = 1, opacity = 1, seed = 78, icon = false,
}) => {
  const state = quotaAt(t);
  const pose = selectedPose ?? state.pose;
  const low = state.runningLow;
  const stroke = low ? "#b63d32" : PALETTE.graphite;
  const fill = low ? "#e78a77" : "#b0b8a9";
  const hatch = low ? "#ba453a" : "#687c70";
  const outlineP = sub(draw, 0, 0.65);
  const fillP = sub(draw, 0.35, 0.9);
  const faceP = sub(draw, 0.62, 1);
  const bob = icon ? 0 : pose === "coding" ? Math.sin(t * 5) * 1.8 : pose === "waving" ? Math.sin(t * 3) * 3 : 0;
  const tilt = icon ? 0 : pose === "alarmed" ? -5 : pose === "relieved" ? 3 : 0;
  const options = {stroke, strokeWidth: 3.2, roughness: 1.05, bowing: 0.7};
  const limbs = pose === "alarmed" ? [57, 57] : pose === "sweating" ? [-24, 64] :
    pose === "relieved" ? [-28, -28] : pose === "waving" ? [-36, 60 + Math.sin(t * 8) * 17] :
    pose === "coding" ? [-34 + Math.sin(t * 12) * 4, -40 + Math.sin(t * 12 + 1.2) * 4] : [-65, -65];
  const armLength = (side: number) => pose === "alarmed" || (side > 0 && (pose === "waving" || pose === "sweating")) ? 76 : 50;

  const block = (bx: number, by: number, w: number, h: number, partSeed: number) => <>
    <rect x={bx + 1} y={by + 1} width={w - 2} height={h - 2} fill={PALETTE.paper} opacity={outlineP} />
    <RoughDrawing seed={partSeed} progress={fillP} deps={[bx, by, w, h]}
      options={{stroke: "none", fill: hatch, fillStyle: "hachure", hachureGap: 5.5, fillWeight: 2.2, roughness: 1.2}}
      build={(g, o) => [g.rectangle(bx, by, w, h, o)]} />
    <RoughDrawing seed={partSeed} options={options} progress={outlineP} deps={[bx, by, w, h]}
      build={(g, o) => [g.rectangle(bx, by, w, h, o)]} />
  </>;

  return <g transform={`translate(${x} ${y + bob}) rotate(${tilt}) scale(${scale})`} opacity={opacity}
    data-robot-pose={pose} data-running-low={low}>
    {!icon && <>
      {[-65, 65].map((cx, i) => <g key={cx}>{block(cx - 14, -47, 28, 47, seed + 10 + i)}</g>)}
      {[-1, 1].map((side, i) => <g key={side}
        transform={`rotate(${side < 0 ? limbs[i] : -limbs[i]} ${side * 98} -83)`}>
        {block(side < 0 ? -98 - armLength(side) : 98, -99, armLength(side), 32, seed + 20 + i)}
      </g>)}
    </>}

    {/* A circular antenna and rectangular ears keep the app icon recognizable. */}
    <RoughDrawing seed={seed + 30} progress={outlineP}
      options={{...options, strokeWidth: icon ? 10 : 5}}
      build={(g, o) => [g.line(0, -186, 0, -221, o), g.circle(0, -232, 25, {...o, fill: icon ? stroke : hatch, fillStyle: "solid"})]} />
    {[-1, 1].map((side, i) => <g key={side}>
      {icon ? <rect x={side < 0 ? -126 : 103} y={-114} width={23} height={48} fill={stroke} opacity={outlineP} /> :
        block(side < 0 ? -126 : 103, -114, 23, 48, seed + 32 + i)}
    </g>)}
    <path d={BODY} fill={icon ? stroke : PALETTE.paper} opacity={icon ? outlineP : fillP} />
    {!icon && <>
      <path d={BODY} fill={fill} opacity={fillP * 0.4} />
      <RoughDrawing seed={seed} progress={fillP}
        options={{stroke: "none", fill: hatch, fillStyle: "hachure", hachureAngle: -48, hachureGap: 7, fillWeight: 2.1, roughness: 1.3}}
        build={(g, o) => [g.path(BODY, o)]} />
      <RoughDrawing seed={seed + 1} progress={fillP * 0.65}
        options={{stroke: "none", fill: hatch, fillStyle: "hachure", hachureAngle: 43, hachureGap: 17, fillWeight: 1.1, roughness: 1.4}}
        build={(g, o) => [g.path(BODY, o)]} />
    </>}
    <RoughDrawing seed={seed + 2} options={options} progress={outlineP} build={(g, o) => [g.path(BODY, o)]} />

    <g opacity={faceP}>
      {[-46, 46].map((cx, i) => <RobotEye key={cx} cx={cx} pose={icon ? "proud" : pose}
        blink={!icon && (t + 0.7) % 3.1 > 2.98} ink={icon ? PALETTE.paper : PALETTE.ink} seed={seed + 40 + i} />)}
      {!icon && pose === "alarmed" && <RoughDrawing seed={seed + 44}
        options={{stroke: PALETTE.ink, fill: PALETTE.ink, fillStyle: "solid", strokeWidth: 2}}
        build={(g, o) => [g.ellipse(0, -68, 15, 20, o)]} />}
      {!icon && pose === "relieved" && <RoughDrawing seed={seed + 45}
        options={{stroke: PALETTE.ink, strokeWidth: 3, roughness: 0.7}}
        build={(g, o) => [g.curve([[-17, -77], [0, -70], [17, -77]], o)]} />}
    </g>

    {!icon && pose === "sweating" && <g opacity={faceP}>
      {[0, 1].map((drop) => <g key={drop} transform={`translate(${128 + drop * 20} ${-161 + ((t * 24 + drop * 21) % 39)})`}>
        <RoughDrawing seed={seed + 50 + drop} options={{stroke: "#557f91", fill: "#a1c8ce", fillStyle: "hachure", fillWeight: 2, strokeWidth: 2.8}}
          build={(g, o) => [g.path("M 0 -14 C -4 -7 -10 1 -8 7 C -4 16 8 13 9 6 C 10 1 5 -7 0 -14 Z", o)]} />
      </g>)}
    </g>}
    {!icon && pose === "alarmed" && <RoughDrawing seed={seed + 54} progress={faceP}
      options={{stroke: PALETTE.pencil, strokeWidth: 3}}
      build={(g, o) => [g.line(-148, -211, -164, -229, o), g.line(-124, -224, -127, -249, o), g.line(132, -209, 150, -227, o)]} />}
    {!icon && pose === "coding" && <RobotLaptop draw={draw} seed={seed + 60} />}
  </g>;
};

const RobotEye: React.FC<{cx: number; pose: RobotPose; blink: boolean; ink: string; seed: number}> =
  ({cx, pose, blink, ink, seed}) => {
    const options = {stroke: ink, strokeWidth: 6, roughness: 0.65, bowing: 0.4};
    return <RoughDrawing seed={seed} options={options} deps={[cx, pose, blink]}
      build={(g, o) => {
        if (blink || pose === "relieved") return [g.curve([[cx - 18, -112], [cx, -104], [cx + 18, -112]], o)];
        if (pose === "alarmed") return [g.ellipse(cx, -118, 19, 29, {...o, fill: ink, fillStyle: "solid", strokeWidth: 2})];
        if (pose === "sweating") return [g.line(cx - 17, -120, cx + 14, -112, o), g.line(cx + 4, -108, cx + 4, -95, {...o, strokeWidth: 4})];
        if (pose === "coding") return [g.line(cx - 15, -119, cx + 15, -119, o), g.line(cx + 7, -117, cx + 7, -104, {...o, strokeWidth: 4})];
        return [g.linearPath([[cx - 20, -108], [cx, -128], [cx + 20, -108]], o)];
      }} />;
  };

const RobotLaptop: React.FC<{draw: number; seed: number}> = ({draw, seed}) => <g>
  <RoughDrawing seed={seed} progress={sub(draw, 0.5, 1)}
    options={{stroke: PALETTE.graphite, fill: PALETTE.cream, fillStyle: "solid", strokeWidth: 3, roughness: 0.8}}
    build={(g, o) => [g.polygon([[-49, -92], [138, -92], [120, -13], [-37, -13]], o),
      g.polygon([[-62, -13], [132, -13], [145, -2], [-71, -2]], o)]} />
  <RoughDrawing seed={seed + 1} progress={sub(draw, 0.72, 1)}
    options={{stroke: PALETTE.pencil, strokeWidth: 2.5, roughness: 0.7}}
    build={(g, o) => [g.linearPath([[32, -66], [22, -57], [32, -48]], o), g.line(49, -69, 40, -44, o),
      g.linearPath([[58, -66], [68, -57], [58, -48]], o)]} />
</g>;
