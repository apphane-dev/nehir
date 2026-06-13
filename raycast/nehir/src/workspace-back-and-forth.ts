import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Back and Forth Workspace", ["command", "switch-workspace", "back-and-forth"]);
}
