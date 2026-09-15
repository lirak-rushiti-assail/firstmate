// Firstmate Codex quota status for Pi sessions.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installCodexQuotaIndicator } from "./lib/fm-codex-quota.ts";

export default function (pi: ExtensionAPI): void {
  installCodexQuotaIndicator(pi);
}
