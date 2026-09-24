import { cn } from "@/shared/lib/cn";
// The pulse keyframes live here. This import is load-bearing: the stylesheet
// used to be pulled in by BuzzLogoAnimation, which nothing references anymore,
// so without it the mark renders but never animates.
import "./buzz-logo-animation.css";
import aitacoMarkUrl from "./aitaco-mark.png?inline";

/**
 * The aitaco robot-taco mark: white on a teal disc, as on aitaco.co.
 *
 * A bitmap rather than a `currentColor` path, deliberately. The mark carries
 * its own ground, so it reads at every size and in both themes without
 * borrowing the theme's foreground — and below about 36px a monochrome trace
 * of it does not read at all, because the robot head's antennae and eyes go
 * sub-pixel long before the taco shell does. The smallest slots that render it
 * (link previews at 12px, repository cards at 14x16) sit next to other vendor
 * bitmaps anyway, so a disc is also the treatment that matches its neighbours.
 *
 * `object-contain` keeps the disc circular in the non-square boxes some call
 * sites pass (e.g. `h-3.5 w-4`), which a bare `<img>` would render as an
 * ellipse. Mobile renders the same asset through `AitacoMark` in
 * `mobile/lib/shared/widgets/aitaco_mark.dart`.
 */
export function AitacoMark({
  ariaLabel,
  className,
}: {
  ariaLabel?: string;
  className?: string;
}) {
  return (
    <img
      alt={ariaLabel ?? ""}
      aria-hidden={ariaLabel ? undefined : "true"}
      className={cn("aitaco-mark object-contain", className)}
      draggable={false}
      role={ariaLabel ? "img" : undefined}
      src={aitacoMarkUrl}
    />
  );
}
