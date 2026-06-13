import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Move Window Up", ["command", "move-window-up"]);
}
