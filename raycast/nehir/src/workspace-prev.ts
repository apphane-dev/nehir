import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Previous Workspace", ["command", "switch-workspace", "prev"]);
}
