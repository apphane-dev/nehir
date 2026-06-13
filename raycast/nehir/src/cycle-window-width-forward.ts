import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Cycle Window Width Forward", ["command", "cycle-window-width", "forward"]);
}
