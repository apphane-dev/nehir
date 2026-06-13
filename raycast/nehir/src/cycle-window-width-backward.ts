import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Cycle Window Width Backward", ["command", "cycle-window-width", "backward"]);
}
