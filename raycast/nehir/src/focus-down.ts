import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Down", ["command", "focus", "down"]);
}
