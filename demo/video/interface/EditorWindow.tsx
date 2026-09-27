import { RoughDrawing } from "../rough/RoughDrawing";
import { Frame, Label, Rule, TrafficLights, UI_TEXT, type WindowPosition } from "./shared";

/** A sketch of the editor context, with the story's rate-limit message. */
export const EditorWindow: React.FC<WindowPosition & { showLimit?: boolean }> = ({ x = 0, y = 0, width = 940, drawProgress = 1, showLimit = false }) =>
  <svg x={x} y={y} width={width} height={510 * width / 940} viewBox="0 0 940 510" overflow="visible">
    <Frame width={940} height={510} seed={7971} progress={drawProgress} />
    <TrafficLights />
    <Label x={470} y={36} size={23} anchor="middle" color={UI_TEXT.muted}>usage-pace.ts</Label>
    <Rule x={1} y={53} width={938} />
    {Array.from({ length: 7 }, (_, index) => <g key={index}>
      <Label x={35} y={105 + index * 39} size={20} color="#9a9286">{index + 1}</Label>
      <RoughDrawing seed={7980 + index} options={{ stroke: index === 4 ? "#8a936f" : index % 2 ? "#a37867" : "#74919a", strokeWidth: 7, roughness: 0.65 }}
        build={(g, o) => [g.line(79 + (index % 3) * 23, 98 + index * 39, 268 + (index % 4) * 26, 98 + index * 39, o), g.line(388, 98 + index * 39, 558 + (index % 3) * 59, 98 + index * 39, o)]} />
    </g>)}
    <Rule x={30} y={380} width={880} />
    {showLimit && <>
      <rect x={32} y={401} width={876} height={77} rx={7} fill="#f2e3dc" />
      <Label x={62} y={450} size={32} color="#9e4436" weight={600}>rate limit reached</Label>
    </>}
  </svg>;
