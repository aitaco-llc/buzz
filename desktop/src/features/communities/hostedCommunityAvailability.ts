type HostedCommunityE2eWindow = Window & {
  __BUZZ_E2E__?: { hostedCommunities?: boolean };
};

/**
 * Whether this build offers creating or claiming a community on Block's
 * hosted service (Builderlab).
 *
 * The aitaco build does not: our communities live on our own relay, so every
 * entry point into Builderlab hosting is hidden. Dev and E2E builds with an
 * E2E config keep the dormant flows reachable (unless the config sets
 * `hostedCommunities: false`) so their existing tests still run.
 */
export function isHostedCommunityCreationEnabled(): boolean {
  if (!(import.meta.env.DEV || import.meta.env.MODE === "e2e")) {
    return false;
  }
  const config = (window as HostedCommunityE2eWindow).__BUZZ_E2E__;
  return config !== undefined && config.hostedCommunities !== false;
}
