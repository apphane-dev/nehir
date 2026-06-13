import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Fullscreen", ["command", "toggle-fullscreen"]);
}
