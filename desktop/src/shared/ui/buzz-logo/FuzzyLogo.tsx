import { cn } from "@/shared/lib/cn";
import { AitacoMark } from "./AitacoMark";

export type FuzzyLogoProps = {
  /** No longer meaningful: the feTurbulence texture went with the bee. */
  fuzz?: boolean;
  className?: string;
  ariaLabel?: string;
  loop?: boolean;
  /** No longer meaningful: there is no play cycle to rest between. */
  loopRestSeconds?: number;
  /** Set false when a parent drives its own opacity animation over the mark. */
  pulse?: boolean;
  /** No longer meaningful: there is no morph to reverse. */
  reverse?: boolean;
  /** No longer meaningful: the v8 keyframes were the bee's geometry. */
  variant?: string;
};

/**
 * The app's soft loading mark.
 *
 * Was the Buzz bee's v8 morph, animated with SMIL and textured with a looping
 * `feTurbulence` filter — both of which paint on WebKit's main thread, and the
 * texture was CPU-heavy enough that its own prop doc said so. The aitaco mark
 * replaces it with a compositor `transform`, which is cheaper and does not
 * stall behind main-thread work.
 *
 * The prop surface is kept so the call sites do not churn through the 1.0.0
 * cut. The props describing the bee's morph and texture are now inert; they
 * are typed rather than removed so nothing has to change at the call site, and
 * they should go with the motion work that follows this build.
 */
export function FuzzyLogo({
  className,
  ariaLabel = "aitaco logo",
  pulse = true,
}: FuzzyLogoProps) {
  return (
    <AitacoMark
      ariaLabel={ariaLabel}
      className={cn(pulse && "aitaco-mark--pulse", className)}
    />
  );
}
