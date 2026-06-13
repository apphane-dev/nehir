import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Next Workspace", ["command", "switch-workspace", "next"]);
}
