import { expect, test, type Page } from "@playwright/test";
import { installMockBridge } from "../helpers/bridge";
import { openSettings } from "../helpers/settings";

// The aitaco build offers no entry point into Block's Builderlab hosting.
// `hostedCommunities: false` puts the E2E build in that production shape;
// other specs keep the dormant flows reachable.
async function hideHostedCommunities(page: Page) {
  await page.addInitScript(() => {
    const testWindow = window as Window & {
      __BUZZ_E2E__?: Record<string, unknown>;
    };
    testWindow.__BUZZ_E2E__ = {
      ...(testWindow.__BUZZ_E2E__ ?? {}),
      hostedCommunities: false,
    };
  });
}

test("welcome offers join and reconnect, never create or own", async ({
  page,
}) => {
  await installMockBridge(page, {}, { skipCommunitySeed: true });
  await hideHostedCommunities(page);
  await page.goto("/");

  await expect(
    page.getByRole("heading", { name: "Join a community" }),
  ).toBeVisible();
  await expect(page.getByTestId("community-choice-join")).toBeVisible();
  await expect(page.getByTestId("community-choice-create")).toHaveCount(0);
  await expect(page.getByText("Create a community")).toHaveCount(0);

  // "I already have a community" skips the owner/member chooser.
  await page.getByTestId("community-choice-existing").click();
  await expect(
    page.getByRole("heading", { name: "Reconnect to your community" }),
  ).toBeVisible();
  await expect(page.getByTestId("existing-choice-owner")).toHaveCount(0);
  await expect(page.getByText("I own the community")).toHaveCount(0);
  await expect(
    page.getByPlaceholder("Invite link or community URL"),
  ).toBeVisible();

  await page.getByTestId("welcome-member-back").click();
  await expect(
    page.getByRole("heading", { name: "Join a community" }),
  ).toBeVisible();
});

test("add community opens on the join form with no create option", async ({
  page,
}) => {
  await installMockBridge(page, {});
  await hideHostedCommunities(page);
  await page.goto("/");

  await page.getByTestId("sidebar-profile-avatar-button").click();
  await page.getByTestId("community-switcher").click();
  await page.getByRole("menuitem", { name: "Add a community" }).click();

  await expect(
    page.getByRole("heading", { name: "Join an existing community" }),
  ).toBeVisible();
  await expect(page.getByLabel("Community URL or invite link")).toBeVisible();
  await expect(page.getByTestId("add-community-create")).toHaveCount(0);
  await expect(page.getByTestId("add-community-back")).toHaveCount(0);
  await expect(page.getByText("Builderlab")).toHaveCount(0);
});

test("settings has no hosted communities section", async ({ page }) => {
  await installMockBridge(page, {});
  await hideHostedCommunities(page);
  await page.goto("/");

  await openSettings(page);
  await expect(page.getByTestId("settings-nav-profile")).toBeVisible();
  await expect(page.getByTestId("settings-nav-hosted-communities")).toHaveCount(
    0,
  );
  await expect(page.getByText("Hosted communities")).toHaveCount(0);
  await expect(page.getByTestId("hosted-communities-settings")).toHaveCount(0);
});
