import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move to Workspace Up", ["command", "move-to-workspace", "up"]);
}
