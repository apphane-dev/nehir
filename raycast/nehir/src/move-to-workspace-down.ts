import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move to Workspace Down", ["command", "move-to-workspace", "down"]);
}
