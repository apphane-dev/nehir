import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Workspace Bar", ["command", "toggle-workspace-bar"]);
}
