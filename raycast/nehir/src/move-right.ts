import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Right", ["command", "move", "right"]);
}
