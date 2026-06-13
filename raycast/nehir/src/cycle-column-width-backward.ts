import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Cycle Column Width Backward", ["command", "cycle-column-width", "backward"]);
}
