import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Cycle Column Width Forward", ["command", "cycle-column-width", "forward"]);
}
