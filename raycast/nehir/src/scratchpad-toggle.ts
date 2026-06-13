import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Scratchpad", ["command", "scratchpad", "toggle"]);
}
