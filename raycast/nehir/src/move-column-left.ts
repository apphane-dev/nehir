import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Column Left", ["command", "move-column", "left"]);
}
