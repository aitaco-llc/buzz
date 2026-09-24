import { AitacoMark } from "./AitacoMark";

/**
 * The app's animated loading mark.
 *
 * Was the Buzz bee with flapping wings. The aitaco robot-taco has no wings,
 * and the two filling lobes that might stand in for them are half-occluded by
 * the shell — so replacing the flap is a motion design, not a geometry swap,
 * and it is not in the 1.0.0 cut. Until it lands, the mark breathes instead.
 *
 * What is preserved from the flap is the property that actually mattered: the
 * animation is a `transform`, so it runs on the compositor and keeps moving
 * while boot work holds WebKit's main thread — the window the cold boot gate
 * is on screen for. The name and the `{ className }` surface are kept so the
 * call sites do not churn through the cut.
 */
export function FlappingBee({ className }: { className?: string }) {
  return (
    <AitacoMark
      className={["aitaco-mark--pulse", className].filter(Boolean).join(" ")}
    />
  );
}
