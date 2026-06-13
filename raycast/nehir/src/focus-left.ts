import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Left", ["command", "focus", "left"]);
}
