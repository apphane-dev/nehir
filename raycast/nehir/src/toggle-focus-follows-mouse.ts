import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Focus Follows Mouse", ["command", "toggle-focus-follows-mouse"]);
}
