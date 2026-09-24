import { BuzzMark } from "@/shared/ui/buzz-logo/BuzzMark";

/**
 * The landing decoration layer: the corner mark over the chartreuse field.
 *
 * This used to also scatter ~38 drifting bees across the field, each tinted
 * white or yellow and repelled by the pointer. That treatment depended on the
 * mark being a tintable monochrome silhouette — small, flat, taking its colour
 * from the field. The aitaco mark carries its own teal ground, so scattered
 * across chartreuse it reads as the logo pasted 38 times rather than as a
 * field, and the per-bee `color` had nothing left to act on.
 *
 * So the field is out for 1.0.0 rather than shipped wrong. Restoring an
 * equivalent belongs with the vector glyph and the motion work that follow
 * this build, which is what would give it a tintable mark to scatter again.
 */
export function LandingBees() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 overflow-hidden"
    >
      <span className="absolute left-6 top-12 block w-11">
        <BuzzMark className="h-auto w-full" />
      </span>
    </div>
  );
}
