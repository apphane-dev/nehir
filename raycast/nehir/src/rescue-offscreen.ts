import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Rescue Offscreen Windows", ["command", "rescue-offscreen-windows"]);
}
