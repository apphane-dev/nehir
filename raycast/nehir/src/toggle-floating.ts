import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Floating", ["command", "toggle-focused-window-floating"]);
}
