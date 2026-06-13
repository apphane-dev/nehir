import { executeNehir } from "./commands";

export default async function Command() {
  await executeNehir("Toggle Prevent Sleep", ["command", "toggle-prevent-sleep"]);
}
