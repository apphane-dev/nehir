import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Up", ["command", "move", "up"]);
}
