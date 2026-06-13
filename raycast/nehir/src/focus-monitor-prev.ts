import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Previous Monitor", ["command", "focus-monitor", "prev"]);
}
