import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Right", ["command", "focus", "right"]);
}
