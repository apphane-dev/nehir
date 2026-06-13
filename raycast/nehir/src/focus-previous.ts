import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Previous", ["command", "focus", "previous"]);
}
