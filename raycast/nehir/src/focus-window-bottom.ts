import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Focus Window Bottom", ["command", "focus-window", "bottom"]);
}
