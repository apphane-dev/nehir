import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Column Right", ["command", "move-column", "right"]);
}
