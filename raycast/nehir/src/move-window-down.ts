import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Window Down", ["command", "move-window-down"]);
}
