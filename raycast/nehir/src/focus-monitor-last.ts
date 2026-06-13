import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Last Monitor", ["command", "focus-monitor", "last"]);
}
