import { RecoveryScreen } from "./RecoveryScreen";

export function RelaunchRequiredScreen() {
  return (
    <RecoveryScreen
      testId="relaunch-required"
      title="Restart aitaco to finish recovery"
      body="Your identity was updated. aitaco needs to restart so syncing and agents run under it."
    />
  );
}
