import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Up", ["command", "focus", "up"]);
}
