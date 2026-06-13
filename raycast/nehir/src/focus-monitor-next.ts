import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Next Monitor", ["command", "focus-monitor", "next"]);
}
