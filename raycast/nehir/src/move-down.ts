import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Down", ["command", "move", "down"]);
}
