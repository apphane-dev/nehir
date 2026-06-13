import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Assign Scratchpad", ["command", "scratchpad", "assign"]);
}
