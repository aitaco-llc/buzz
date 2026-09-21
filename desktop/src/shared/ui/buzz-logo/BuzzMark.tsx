import { AitacoMark } from "./AitacoMark";

/**
 * The app's static mark. Now the aitaco robot-taco rather than the Buzz bee;
 * the name is kept so the ~8 call sites and the `buzz-mark` styling hook stay
 * put through the 1.0.0 cut.
 *
 * The bee was a `currentColor` silhouette that tinted per-theme. The aitaco
 * mark carries its own ground instead — see {@link AitacoMark} for why. Call
 * sites that passed a `text-*` class still compile; the class simply no longer
 * colours the mark.
 */
export function BuzzMark({ className }: { className?: string }) {
  return (
    <AitacoMark
      className={["buzz-mark", className].filter(Boolean).join(" ")}
    />
  );
}
