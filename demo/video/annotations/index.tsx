import { RoughDrawing } from "../rough/RoughDrawing";

const RED_PEN = "#b13c35";
interface PenProps { progress?: number; seed?: number; color?: string }

export const RedPenCircle: React.FC<PenProps & { x: number; y: number; width: number; height: number }> =
  ({ x, y, width, height, progress = 1, seed = 7930, color = RED_PEN }) =>
    <RoughDrawing seed={seed} progress={progress} options={{ stroke: color, strokeWidth: 3.7, roughness: 1.4, bowing: 1.6 }} deps={[x, y, width, height]}
      build={(g, o) => [g.ellipse(x + width / 2, y + height / 2, width, height, o)]} />;

export const RedPenStrike: React.FC<PenProps & { x: number; y: number; width: number }> =
  ({ x, y, width, progress = 1, seed = 7931, color = RED_PEN }) =>
    <RoughDrawing seed={seed} progress={progress} options={{ stroke: color, strokeWidth: 3.6, roughness: 1.1 }} deps={[x, y, width]}
      build={(g, o) => [g.line(x, y + 2, x + width, y - 4, o), g.line(x + 5, y + 9, x + width - 3, y + 3, o)]} />;

export const RedPenTick: React.FC<PenProps & { x: number; y: number; size?: number }> =
  ({ x, y, size = 54, progress = 1, seed = 7932, color = RED_PEN }) =>
    <RoughDrawing seed={seed} progress={progress} options={{ stroke: color, strokeWidth: 4, roughness: 0.8 }} deps={[x, y, size]}
      build={(g, o) => [g.path(`M ${x} ${y + size * 0.5} L ${x + size * 0.32} ${y + size * 0.85} L ${x + size} ${y}`, o)]} />;

export const RedPenArrow: React.FC<PenProps & { from: { x: number; y: number }; to: { x: number; y: number }; bend?: number }> =
  ({ from, to, bend = 0, progress = 1, seed = 7933, color = RED_PEN }) => {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length = Math.max(1, Math.hypot(dx, dy));
    const control = { x: (from.x + to.x) / 2 - dy / length * bend, y: (from.y + to.y) / 2 + dx / length * bend };
    const angle = Math.atan2(to.y - control.y, to.x - control.x);
    const left = { x: to.x - 23 * Math.cos(angle - 0.45), y: to.y - 23 * Math.sin(angle - 0.45) };
    const right = { x: to.x - 23 * Math.cos(angle + 0.45), y: to.y - 23 * Math.sin(angle + 0.45) };
    return <RoughDrawing seed={seed} progress={progress} options={{ stroke: color, strokeWidth: 3.5, roughness: 1.05 }} deps={[from.x, from.y, to.x, to.y, bend]}
      build={(g, o) => [g.path(`M ${from.x} ${from.y} Q ${control.x} ${control.y} ${to.x} ${to.y}`, o), g.path(`M ${left.x} ${left.y} L ${to.x} ${to.y} L ${right.x} ${right.y}`, o)]} />;
  };
