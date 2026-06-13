import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Up or Right", ["command", "focus", "up-or-right"]);
}
