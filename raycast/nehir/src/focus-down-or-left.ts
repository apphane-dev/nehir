import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Down or Left", ["command", "focus", "down-or-left"]);
}
