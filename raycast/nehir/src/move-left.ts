import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Left", ["command", "move", "left"]);
}
